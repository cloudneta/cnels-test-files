#!/usr/bin/env bash
# CNELS BASIC hands-on. Run as ec2-user on EKS-BASTION.
set -eu
case "${1:-}" in
    prepare|gpu-tools|dashboard|serve|load) ;;
    *) echo "Usage: bash $0 {prepare|gpu-tools|dashboard|serve|load}" >&2; exit 2 ;;
esac
exec python3 -u - "$1" <<'CNELS_PY'
import base64
import contextlib
import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess as sp
import sys
import tempfile
import time
from urllib.parse import urlencode
from urllib.request import Request, urlopen

CLUSTER = "cnels-basic"
REGION = "ap-northeast-2"
CPU, GPU = "cnels-cpu", "cnels-gpu"
NODE_LABEL = "eks.amazonaws.com/nodegroup"
MODEL = "Qwen/Qwen3-4B"
GUIDE = "ghcr.io/vllm-project/guidellm:v0.8.1@sha256:015b22441020e6014b4c06d89882921eb29e9b9a6f2e274b253afef4029aa081"
LLM = "llm"
MON = "monitoring"
UID = "cnels-basic-serving"
os.umask(0o077)
os.environ.update(AWS_DEFAULT_REGION=REGION, AWS_REGION=REGION, AWS_PAGER="")
root = Path.home() / ".cache" / "cnels-basic-lab"
root.mkdir(parents=True, exist_ok=True)
lock = (root / "run.lock").open("a")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit("Another CNELS BASIC run is active.")
out = Path(tempfile.mkdtemp(prefix="result-", dir=root))
stage = "preflight"
target_ok = False

def note(message):
    line = "%s %s" % (datetime.datetime.now().astimezone().isoformat(timespec="seconds"), message)
    print(line, flush=True)
    with (out / "run.log").open("a") as f:
        print(line, file=f)

def save(path, obj):
    path = Path(path)
    temp = path.with_suffix(path.suffix + ".partial")
    temp.write_text(json.dumps(obj, ensure_ascii=False, indent=2))
    temp.replace(path)

def run(*cmd, data=None, timeout=120, echo=False):
    # Buffer results to avoid credentials (Helm Notes / Grafana secret) in the review file.
    p = sp.run([str(c) for c in cmd], input=data, stdout=sp.PIPE, stderr=sp.PIPE,
               text=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError("%s %s (exit %s): %s" % (
            cmd[0], cmd[1], p.returncode, (p.stderr.strip() or p.stdout.strip())[-3000:]))
    if echo and p.stdout.strip():
        note(p.stdout.strip()[-3500:])
    return p.stdout

def k(*args, **kw):
    return run("kubectl", *args, **kw)

def apply(obj):
    k("apply", "-f", "-", data=json.dumps(obj))

def get(ns, resource, name):
    return json.loads(k("-n", ns, "get", resource, name, "-o", "json"))

def wait_for(label, fn, seconds=150):
    deadline = time.monotonic() + seconds
    last = "condition not met"
    while True:
        try:
            value = fn()
            if value:
                return value
        except (OSError, RuntimeError, ValueError, sp.TimeoutExpired) as exc:
            last = str(exc)
        if time.monotonic() >= deadline:
            raise RuntimeError(label + ": " + last)
        time.sleep(5)

def set_stage(name):
    global stage
    stage = name
    note("STEP " + name)

def ns(name):
    apply({"apiVersion":"v1", "kind":"Namespace", "metadata":{"name":name}})

def aws(service, op, *args):
    return json.loads(run("aws", service, op, *args, "--output", "json"))

def preflight():
    global target_ok
    for tool in ["aws", "kubectl", "eksctl", "helm"]:
        if not shutil.which(tool):
            raise RuntimeError("Missing CLI: " + tool)
    cluster = aws("eks", "describe-cluster", "--name", CLUSTER)["cluster"]
    cfg = cluster["resourcesVpcConfig"]
    endpoint = k("config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}")
    if (cluster["status"] != "ACTIVE" or cluster["version"] != "1.37"
            or endpoint != cluster["endpoint"] or cfg["endpointPublicAccess"]
            or not cfg["endpointPrivateAccess"]):
        raise RuntimeError("Expected ACTIVE cnels-basic 1.37, Private Only and matching kubeconfig.")
    target_ok = True
    k("wait", "node", "-l", NODE_LABEL+"="+CPU, "--for=condition=Ready", "--timeout=60s")
    note(k("get", "nodes", "-L", NODE_LABEL).strip())
    note("eksctl " + run("eksctl", "version").strip() + "; Helm " + run("helm", "version", "--short").strip())
    identity = get("default", "namespace", "kube-system")["metadata"]["uid"]
    cache = root / identity
    cache.mkdir(exist_ok=True)
    return cache

def chart_files(cache):
    chartdir = cache / "charts"
    chartdir.mkdir(exist_ok=True)
    cpu = {NODE_LABEL: CPU}
    gpu = {NODE_LABEL: GPU}
    monitoring = {
        "alertmanager":{"enabled":False}, "defaultRules":{"create":False},
        "kubeEtcd":{"enabled":False}, "kubeControllerManager":{"enabled":False},
        "kubeScheduler":{"enabled":False},
        "prometheusOperator":{"nodeSelector":cpu},
        "kube-state-metrics":{"nodeSelector":cpu},
        "grafana":{"nodeSelector":cpu, "defaultDashboardsEnabled":False,
                   "sidecar":{"dashboards":{"enabled":True, "label":"grafana_dashboard",
                                           "labelValue":"1","searchNamespace":MON}}},
        "prometheus":{"prometheusSpec":{"nodeSelector":cpu,"retention":"12h",
                     "resources":{"requests":{"cpu":"100m","memory":"512Mi"},
                                  "limits":{"memory":"2Gi"}}}}}
    charts = [
        ("monitoring","kube-prometheus-stack","https://prometheus-community.github.io/helm-charts","93.1.1",MON,monitoring),
        ("cnels-nvdp","nvidia-device-plugin","https://nvidia.github.io/k8s-device-plugin","0.17.1","kube-system",
         {"nodeSelector":gpu,"affinity":None,"gfd":{"enabled":False},"nfd":{"enabled":False}}),
        ("dcgm-exporter","dcgm-exporter","https://nvidia.github.io/dcgm-exporter/helm-charts","4.9.0",MON,
         {"nodeSelector":gpu,"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}],
          "serviceMonitor":{"enabled":True,"interval":"15s","scrapeTimeout":"10s","additionalLabels":{"release":"monitoring"}}})]
    result = {}
    for release, name, repo, ver, namespace, values in charts:
        dest = chartdir / release
        dest.mkdir(exist_ok=True)
        archives = list(dest.glob(name+"-*.tgz"))
        if not archives:
            args = ["helm","pull",name,"--repo",repo,"--destination",dest]
            if ver:
                args += ["--version",ver]
            run(*args, timeout=240)
            archives = list(dest.glob(name+"-*.tgz"))
        if len(archives) != 1:
            raise RuntimeError("Expected one cached chart in " + str(dest))
        package = archives[0]
        if ver and package.name != name+"-"+ver+".tgz":
            raise RuntimeError("Unexpected chart: "+package.name)
        values_file = dest / "values.json"
        save(values_file, values)
        run("helm","template",release,package,"--namespace",namespace,"--kube-version","1.37.0","-f",values_file,timeout=180)
        note("Chart "+package.name)
        result[release] = (release, namespace, package, values_file)
    return result

def install(chart):
    release, namespace, package, values_file = chart
    status = json.loads(run("helm","list","-a","-n",namespace,"--filter","^"+release+"$","-o","json"))
    if status and status[0]["status"] == "deployed" and status[0]["chart"] == package.name[:-4]:
        current = json.loads(run("helm","get","values",release,"-n",namespace,"-o","json"))
        if current == json.loads(values_file.read_text()):
            note(release+" already deployed with requested values")
            return
    run("helm","upgrade","--install",release,package,"-n",namespace,"-f",values_file,
        "--wait","--timeout","12m",timeout=800)

def deploy(name, group, container, port=None, service_links=False):
    labels = {"app":name}
    pod = {"nodeSelector":{NODE_LABEL:group}, "enableServiceLinks":service_links,
           "automountServiceAccountToken":False, "containers":[container]}
    if group == GPU:
        pod["tolerations"] = [{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]
    apply({"apiVersion":"apps/v1","kind":"Deployment","metadata":{"namespace":LLM,"name":name},
           "spec":{"replicas":1,"strategy":{"type":"Recreate"},"selector":{"matchLabels":labels},
                   "template":{"metadata":{"labels":labels},"spec":pod}}})
    if port:
        apply({"apiVersion":"v1","kind":"Service","metadata":{"name":name,"namespace":LLM,"labels":labels},
               "spec":{"selector":labels,"ports":[{"name":"http","port":port,"targetPort":port}]}})

def rollout(name, minutes):
    k("-n",LLM,"rollout","status","deployment/"+name,"--timeout="+str(minutes)+"m",timeout=minutes*60+30)

def guide_exec(*args, **kw):
    return k("-n",LLM,"exec","deploy/cnels-guidellm","--",*args,**kw)

def guide_prep():
    deploy("cnels-guidellm",CPU,{"name":"client","image":GUIDE,
           "command":["python","-c","import time; time.sleep(10**8)"],
           "resources":{"requests":{"cpu":"100m","memory":"256Mi"}},
           "env":[{"name":"TOKENIZERS_PARALLELISM","value":"false"},
                  {"name":"OMP_NUM_THREADS","value":"1"}]})
    rollout("cnels-guidellm",12)
    note("GuideLLM "+guide_exec("python","-c","from importlib.metadata import version;print(version('guidellm'))").strip())
    cli = guide_exec("guidellm","run","--help")
    for flag in ["--backend","--data","--profile","--constraint","--output","--seed"]:
        if flag not in cli:
            raise RuntimeError("GuideLLM CLI missing "+flag)
    guide_exec("python","-c","from transformers import AutoTokenizer; import sys; AutoTokenizer.from_pretrained(sys.argv[1])",MODEL,timeout=240)

def gpu_group():
    groups = aws("eks","list-nodegroups","--cluster-name",CLUSTER)["nodegroups"]
    if GPU not in groups:
        flags = run("eksctl","create","nodegroup","--help")
        args = ["eksctl","create","nodegroup","--cluster",CLUSTER,"--region",REGION,"--name",GPU,
                "--node-type","g6.xlarge","--node-ami-family","AmazonLinux2023","--managed",
                "--node-private-networking","--nodes","1","--nodes-min","1","--nodes-max","1","--node-volume-size","100"]
        if "--install-nvidia-plugin" in flags:
            args.append("--install-nvidia-plugin=false")
        note("Creating cnels-gpu (g6.xlarge x 1). Waiting for eksctl.")
        run(*args,timeout=2800,echo=True)
    detail = aws("eks","describe-nodegroup","--cluster-name",CLUSTER,"--nodegroup-name",GPU)["nodegroup"]
    if detail["status"] in ("CREATING","UPDATING"):
        run("aws","eks","wait","nodegroup-active","--cluster-name",CLUSTER,"--nodegroup-name",GPU,timeout=2600)
        detail = aws("eks","describe-nodegroup","--cluster-name",CLUSTER,"--nodegroup-name",GPU)["nodegroup"]
    if (detail["status"]!="ACTIVE" or detail["instanceTypes"]!=["g6.xlarge"]
            or detail["scalingConfig"]!={"desiredSize":1,"maxSize":1,"minSize":1}):
        raise RuntimeError("Unexpected cnels-gpu state: "+str((detail["status"],detail["instanceTypes"],detail["scalingConfig"],detail.get("health"))))
    k("wait","node","-l",NODE_LABEL+"="+GPU,"--for=condition=Ready","--timeout=5m",timeout=330)

def gpu_plugin(chart):
    # Older eksctl builds can install this upstream DaemonSet during nodegroup creation.
    legacy = k("-n","kube-system","get","ds","nvidia-device-plugin-daemonset","--ignore-not-found","-o","json")
    if legacy:
        ds = json.loads(legacy)
        if ds["spec"]["template"]["spec"].get("nodeSelector",{}).get(NODE_LABEL) != GPU:
            patch = {"spec":{"template":{"spec":{"nodeSelector":{NODE_LABEL:GPU}}}}}
            k("-n","kube-system","patch","ds","nvidia-device-plugin-daemonset","--type=merge","-p",json.dumps(patch))
        k("-n", "kube-system", "rollout", "status", "ds/nvidia-device-plugin-daemonset", "--timeout=4m", timeout=260)
    else:
        install(chart)
    def available():
        nodes = json.loads(k("get","nodes","-l",NODE_LABEL+"="+GPU,"-o","json"))["items"]
        return len(nodes)==1 and nodes[0]["status"]["allocatable"].get("nvidia.com/gpu")=="1"
    wait_for("advertised GPU count",available,240)

def serving():
    def probe(path,port):
        return {"httpGet":{"path":path,"port":port},"periodSeconds":10,"timeoutSeconds":5}
    p = probe("/health",8000)
    deploy("vllm",GPU,{"name":"vllm","image":"vllm/vllm-openai:v0.32.0",
        "args":["--model",MODEL,"--max-model-len","4096","--gpu-memory-utilization","0.85"],
        "ports":[{"containerPort":8000}],"startupProbe":dict(p,failureThreshold=90),"readinessProbe":p,
        "resources":{"requests":{"memory":"8Gi","nvidia.com/gpu":"1"},"limits":{"memory":"12Gi","nvidia.com/gpu":"1"}}},8000)
    env={"ENABLE_OLLAMA_API":"false","OPENAI_API_BASE_URL":"http://vllm.llm.svc.cluster.local:8000/v1",
         "OPENAI_API_KEY":"not-needed","DEFAULT_MODEL_METADATA":'{"capabilities":{"builtin_tools":false}}'}
    deploy("open-webui",CPU,{"name":"webui","image":"ghcr.io/open-webui/open-webui:v0.13.3",
        "ports":[{"containerPort":8080}],"env":[{"name":key,"value":v} for key,v in env.items()],
        "readinessProbe":probe("/health",8080)},8080)
    rollout("vllm",26)
    rollout("open-webui",12)
    payload = {"model": MODEL, "messages": [{"role": "user", "content": "서울은 어느 나라의 수도인가요? 한 문장으로 답해 주세요."}],
               "max_tokens": 64, "chat_template_kwargs": {"enable_thinking": False}}
    def chat_request(body):
        return guide_exec("python", "-c",
            "import sys,urllib.request as u; req=u.Request('http://vllm:8000/v1/chat/completions',"
            "data=sys.argv[1].encode(),headers={'Content-Type':'application/json'});"
            "print(u.urlopen(req,timeout=90).read().decode())", json.dumps(body), timeout=120)
    reply = json.loads(chat_request(payload))
    if not reply["choices"][0]["message"].get("content", "").strip():
        raise RuntimeError("Empty chat completion")
    save(out/"chat.json", reply)

    stream = chat_request(dict(payload, stream=True))
    (out/"chat-stream.sse").write_text(stream)
    events = [line[5:].lstrip() for line in stream.splitlines() if line.startswith("data:")]
    if not events or events[-1] != "[DONE]":
        raise RuntimeError("Streaming response ended without [DONE]")
    chunks = [json.loads(event) for event in events[:-1]]
    if any("error" in chunk for chunk in chunks):
        raise RuntimeError("Streaming API returned an error")
    choices = [choice for chunk in chunks for choice in chunk["choices"]]
    answer = "".join(choice["delta"].get("content") or "" for choice in choices)
    if not answer.strip() or not any(choice.get("finish_reason") in ("stop", "length") for choice in choices):
        raise RuntimeError("Streaming response lacks answer text or a normal finish reason")
    note("Streaming chat PASS: received answer text, finish_reason and [DONE]")
    web = guide_exec("python","-c","import urllib.request as u;print(u.urlopen('http://open-webui:8080/health',timeout=8).read().decode())")
    if not json.loads(web).get("status"):
        raise RuntimeError("Open WebUI /health failed: "+web[:200])
    note("vLLM chat returned text; Open WebUI /health passed (browser chat is a separate check).")

def monitor_vllm():
    apply({"apiVersion":"monitoring.coreos.com/v1","kind":"ServiceMonitor",
           "metadata":{"name":"vllm","namespace":MON,"labels":{"release":"monitoring"}},
           "spec":{"namespaceSelector":{"matchNames":[LLM]},"selector":{"matchLabels":{"app":"vllm"}},
                   "endpoints":[{"port":"http","path":"/metrics","interval":"15s","scrapeTimeout":"10s"}]}})

@contextlib.contextmanager
def forward(service, port):
    # Let kubectl reserve an available loopback port rather than overwriting a user's tunnel.
    logfile = out / ("forward-"+service+".log")
    with logfile.open("w") as stream:
        proc = sp.Popen(["kubectl","-n",MON,"port-forward","--address","127.0.0.1","svc/"+service,":"+str(port)],
                        stdout=stream,stderr=sp.STDOUT)
        try:
            def listening():
                if proc.poll() is not None:
                    raise ValueError(logfile.read_text()[-500:])
                match = re.search(r"Forwarding from 127\.0\.0\.1:(\d+)",logfile.read_text())
                return match and "http://127.0.0.1:"+match.group(1)
            yield wait_for("port-forward "+service,listening,35)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except sp.TimeoutExpired:
                    proc.kill()
                    proc.wait()

def http(url, fields=None, headers=None):
    if fields:
        url += "?"+urlencode(fields)
    with urlopen(Request(url,headers=headers or {}),timeout=12) as response:
        return json.load(response)

def prom_request(prom, route, **args):
    obj = http(prom+"/api/v1/"+route,args)
    if obj.get("status") != "success":
        raise RuntimeError("Prometheus query failed: "+str(obj)[:300])
    return obj["data"]["result"]

def choose_panels(prom):
    def present(name):
        return bool(prom_request(prom,"query",query=name))
    def gpu_expr(primary, alternate, factor, alt_factor):
        if present(primary):
            return primary+factor
        if present(alternate):
            return alternate+alt_factor
        raise RuntimeError("Missing DCGM metric: "+primary+" / "+alternate)
    for metric in ["vllm:num_requests_running","vllm:num_requests_waiting","vllm:kv_cache_usage_perc",
                   "vllm:generation_tokens_total","vllm:time_to_first_token_seconds_bucket"]:
        if not present(metric):
            raise RuntimeError("Missing vLLM metric: "+metric)
    def percentile(metric):
        return "histogram_quantile(0.95, sum by (le) (rate("+metric+"_bucket[1m]))) * 1000"
    panels = [
        ("Running requests","short","sum(vllm:num_requests_running)"),
        ("Waiting requests","short","sum(vllm:num_requests_waiting)"),
        ("KV cache used","percent","max(vllm:kv_cache_usage_perc) * 100"),
        ("GPU utilization","percent",gpu_expr("DCGM_FI_DEV_GPU_UTIL_RATIO","DCGM_FI_DEV_GPU_UTIL"," * 100","")),
        ("GPU memory used (GiB)","suffix: GiB",gpu_expr("DCGM_FI_DEV_FB_USED_BYTES","DCGM_FI_DEV_FB_USED"," / 1024^3"," / 1024")),
        ("Generated tokens/s","suffix: tok/s","sum(rate(vllm:generation_tokens_total[1m]))"),
        ("Server TTFT p95","ms",percentile("vllm:time_to_first_token_seconds"))]
    if present("vllm:request_time_per_output_token_seconds_bucket"):
        panels.append(("Server per-request TPOT p95","ms",percentile("vllm:request_time_per_output_token_seconds")))
    elif present("vllm:inter_token_latency_seconds_bucket"):
        panels.append(("Server inter-token latency p95","ms",percentile("vllm:inter_token_latency_seconds")))
    return panels

def dashboard(panels, datasource):
    ds = {"type":"prometheus","uid":datasource}
    charts=[]
    for i,(title,unit,query) in enumerate(panels):
        charts.append({"id":i+1,"title":title,"type":"timeseries","datasource":ds,
                       "gridPos":{"x":12*(i%2),"y":8*(i//2),"h":8,"w":12},
                       "fieldConfig":{"defaults":{"unit":unit},"overrides":[]},
                       "targets":[{"refId":"A","expr":query,"range":True,"datasource":ds}]})
    return {"uid":UID,"title":"CNELS BASIC | LLM Serving","schemaVersion":39,"editable":False,
            "timezone":"browser","refresh":"15s","time":{"from":"now-30m","to":"now"},
            "tags":["CNELS","BASIC"],"panels":charts}

def publish_dashboard(grafana,panels):
    secret = get(MON,"secret","monitoring-grafana")["data"]
    auth = base64.b64encode(base64.b64decode(secret["admin-user"])+b":"+base64.b64decode(secret["admin-password"])).decode()
    headers = {"Authorization":"Basic "+auth}
    sources = http(grafana+"/api/datasources",headers=headers)
    ds = next(s["uid"] for s in sources if s["type"]=="prometheus" and s["isDefault"])
    board = dashboard(panels,ds)
    save(out/"dashboard.json",board)
    apply({"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":UID,"namespace":MON,
           "labels":{"grafana_dashboard":"1"}},"data":{"cnels-basic.json":json.dumps(board)}})
    def loaded():
        obj = http(grafana+"/api/dashboards/uid/"+UID,headers=headers)
        actual = obj["dashboard"]["panels"]
        return [p["targets"][0]["expr"] for p in actual] == [p[2] for p in panels]
    wait_for("Grafana dashboard import",loaded,180)
    # Verify Grafana itself can query the configured datasource, not just import JSON.
    probe = http(grafana+"/api/datasources/proxy/uid/"+ds+"/api/v1/query",
                 {"query":"vllm:num_requests_running"},headers)
    if probe.get("status")!="success" or not probe["data"]["result"]:
        raise RuntimeError("Grafana datasource returned no vLLM series")
    note("Grafana dashboard + datasource query PASS: "+board["title"])

def service_for_port(port):
    objects = json.loads(k("-n",MON,"get","svc","-o","json"))["items"]
    candidates = [s["metadata"]["name"] for s in objects if s["spec"].get("clusterIP")!="None"
                  and s["metadata"]["name"].startswith("monitoring-")
                  and any(p["port"]==port for p in s["spec"]["ports"])]
    if len(candidates)!=1:
        raise RuntimeError("Expected one monitoring Service on port %s, found %s" % (port,candidates))
    return candidates[0]

def exec_benchmark(streams, directory):
    remote = "/tmp/cnels-"+out.name+"-"+str(streams)+".json"
    args = ["guidellm","run","--backend","kind=openai_http,target=http://vllm.llm.svc.cluster.local:8000,model="+MODEL,
            "--data","kind=synthetic_text,prompt_tokens=128,output_tokens=64",
            "--seed","kind=static,value=42","--profile","kind=concurrent,streams="+str(streams),
            "--constraint","kind=max_duration,seconds=90","--output","kind=json,path="+remote,
            "--disable-console-interactive"]
    # Remote timeout also bounds the workload if the Bastion terminal disconnects.
    wrapper = ("import subprocess,sys; "
               "sys.exit(subprocess.run(sys.argv[1:],timeout=600).returncode)")
    start = int(time.time())
    console = guide_exec("python","-c",wrapper,*args,timeout=650)
    end = int(time.time())
    (directory/"guide-console.txt").write_text(console)
    report = json.loads(guide_exec("cat",remote,timeout=120))
    save(directory/"guide.json",report)
    guide_exec("rm","-f",remote)
    return start,end,report

def summary(report):
    benchmarks = report["benchmarks"]
    if len(benchmarks)!=1:
        raise RuntimeError("Expected one GuideLLM sub-benchmark")
    m = benchmarks[0]["metrics"]
    counts = m["request_totals"]
    if counts["successful"] < 1 or counts["errored"] != 0:
        raise RuntimeError("GuideLLM request counts: "+str(counts))
    result = {"requests":counts}
    for key in ["time_to_first_token_ms","time_per_output_token_ms","output_tokens_per_second"]:
        val = m[key]["successful"]["mean"]
        if not isinstance(val,(float,int)) or not math.isfinite(val) or val<=0:
            raise RuntimeError("Missing or invalid GuideLLM "+key)
        result[key] = val
    return result

def benchmarks(prom,panels):
    rows=[]
    for streams in (1,4,16):
        set_stage("GuideLLM concurrency "+str(streams))
        key = "concurrency-"+str(streams)
        files = out / key
        files.mkdir()
        start,end,report = exec_benchmark(streams,files)
        row = summary(report)
        row.update(streams=streams, client_command_start_epoch=start, client_command_end_epoch=end,
                   prompt_tokens_target=128,output_tokens_target=64,profile_seconds=90)
        benchmark = report["benchmarks"][0]
        timings = benchmark.get("scheduler_metrics", {})
        start = benchmark.get("start_time") or timings.get("measure_start_time")
        end = benchmark.get("end_time") or timings.get("measure_end_time")
        if not start or not end or end <= start:
            raise RuntimeError("Missing GuideLLM measurement timestamps; raw report retained")
        row.update(measurement_start_epoch=start, measurement_end_epoch=end)
        # Align server samples to GuideLLM's measurement window, excluding CLI setup.
        series = {}
        time.sleep(16)
        for title,unit,expr in panels:
            result = prom_request(prom,"query_range",query=expr,start=start,end=end,step="15s")
            series[title] = {"unit":unit,"promql":expr,"series":result}
        save(files/"prometheus.json",series)
        for title in ["GPU utilization","GPU memory used (GiB)","Waiting requests","Running requests","Generated tokens/s","Server TTFT p95"]:
            nums = [float(value) for s in series[title]["series"] for _,value in s["values"] if math.isfinite(float(value))]
            if not nums:
                raise RuntimeError("No finite Prometheus samples: "+title)
            row[title+" (max sampled)"] = max(nums)
        save(files/"summary.json",row)
        rows.append(row)
        note(f"동시 요청 {streams}개 완료 | {row['output_tokens_per_second']:.0f} tok/s")
    save(out/"comparison.json",rows)

def main():
    cache = preflight()
    mode = sys.argv[1]
    if mode == "prepare":
        set_stage("chart download and local render")
        charts = chart_files(cache)
        ns(LLM)
        ns(MON)
        set_stage("GuideLLM client + tokenizer preflight on CPU")
        guide_prep()
        set_stage("Prometheus and Grafana")
        install(charts["monitoring"])
        monitor_vllm()
        return
    if mode in ("serve", "gpu-tools"):
        charts = chart_files(cache)
        if mode == "serve":
            set_stage("one g6.xlarge GPU node")
            gpu_group()
        set_stage("GPU device plugin")
        gpu_plugin(charts["cnels-nvdp"])
        set_stage("DCGM Exporter")
        install(charts["dcgm-exporter"])
        if mode == "gpu-tools":
            return
        set_stage("vLLM + Open WebUI")
        serving()
    set_stage("Prometheus metrics and Grafana dashboard")
    with forward(service_for_port(9090),9090) as prom:
        panels = wait_for("vLLM/DCGM scrape",lambda:choose_panels(prom),210)
        if mode in ("serve", "dashboard"):
            with forward("monitoring-grafana",80) as grafana:
                publish_dashboard(grafana,panels)
        else:
            benchmarks(prom,panels)
            results = Path.home() / "cnels-basic-results"
            results.mkdir(exist_ok=True)
            comparison = results / "latest-comparison.json"
            save(comparison, json.loads((out / "comparison.json").read_text()))
            note("비교 결과 " + str(comparison))


def stopped(signum, frame):
    raise KeyboardInterrupt("signal "+str(signum))

def diagnose():
    for namespace in (LLM,MON,"kube-system"):
        for args,filename in [(("get","pods","-o","wide"),"pods"),(("get","events","--field-selector","type=Warning","--sort-by=.lastTimestamp"),"warnings")]:
            try:
                (out/(namespace+"-"+filename+".txt")).write_text(k("-n",namespace,*args,timeout=12)[-12000:])
            except Exception:
                pass
    if stage in ("vLLM + Open WebUI", "Prometheus metrics and Grafana dashboard") or stage.startswith("GuideLLM concurrency"):
        for name in ("vllm","open-webui"):
            for previous in (False,True):
                args = ["--previous"] if previous else []
                try:
                    tail = k("-n",LLM,"logs","deployment/"+name,"--tail=60",*args,timeout=8)
                    (out/(name+("-previous" if previous else "")+".log")).write_text(tail)
                except Exception:
                    pass
    try:
        group = aws("eks","describe-nodegroup","--cluster-name",CLUSTER,"--nodegroup-name",GPU)["nodegroup"]
        save(out/"gpu-status.json",{key:group.get(key) for key in ["status","health","scalingConfig"]})
    except Exception:
        pass

def entrypoint():
    signal.signal(signal.SIGTERM,stopped)
    succeeded = False
    try:
        main()
        succeeded = True
        note("RESULT=PASS")
    except (Exception,KeyboardInterrupt) as exc:
        note("RESULT=FAIL | "+stage+" | "+str(exc))
        if target_ok:
            diagnose()
    finally:
        if succeeded:
            shutil.rmtree(out)
        else:
            print("진단 로그 " + str(out), flush=True)
    return 0 if succeeded else 1

if __name__ == "__main__":
    sys.exit(entrypoint())
CNELS_PY
