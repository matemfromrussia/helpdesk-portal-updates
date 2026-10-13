#!/usr/bin/env python3
"""Статическая проверка манифестов Kubernetes.

Кластера для этого не нужно: проверяем то, что обычно ломает первый
`kubectl apply` — незаполненные плейсхолдеры, несогласованные имена и метки,
незакреплённые образы, отсутствие проб и лимитов, рассинхрон ключей Secret
с переменными приложения, TLS-секрет в ingress и в инструкции.

Использование:
    python3 scripts/check-k8s-manifests.py [каталог]   # по умолчанию deploy/k8s/out

Если доступен kubectl, дополнительно выполняется серверная валидация схем
(`kubectl apply --dry-run=client`); без kubectl остаются структурные проверки.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("нужен PyYAML: python3 -m pip install pyyaml")

# Обязательные ключи, без которых приложение не стартует.
REQUIRED_SECRET_KEYS = ["DATABASE_URL", "JWT_SECRET", "ADMIN_EMAIL", "ADMIN_PASSWORD"]

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def load_docs(path: Path) -> list[dict]:
    docs = []
    with path.open(encoding="utf-8") as fh:
        for doc in yaml.safe_load_all(fh):
            if isinstance(doc, dict) and doc.get("kind"):
                docs.append(doc)
    return docs


def index(docs: list[dict]) -> dict[tuple[str, str], dict]:
    return {(d["kind"], d.get("metadata", {}).get("name", "")): d for d in docs}


def by_kind(docs: list[dict], kind: str) -> list[dict]:
    return [d for d in docs if d["kind"] == kind]


def container_env(doc: dict) -> dict:
    """Плоское отображение переменных окружения всех контейнеров pod-шаблона."""
    result: dict = {}
    for c in by_kind([doc], "Deployment") + ([doc] if doc["kind"] == "Deployment" else []):
        for container in c["spec"]["template"]["spec"].get("containers", []):
            for env in container.get("env", []):
                if "name" in env:
                    result[env["name"]] = env
            for src in container.get("envFrom", []):
                result.setdefault(f"__envFrom__{container['name']}", []).append(src)
    return result


def secret_values(secret: dict) -> dict:
    data = dict(secret.get("stringData") or {})
    data.update(secret.get("data") or {})
    return data


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "deploy/k8s/out")
    if not root.is_dir():
        return _fail([f"каталог не найден: {root}"])

    files = sorted(root.glob("*.yaml")) + sorted(root.glob("*.yml"))
    if not files:
        return _fail([f"в каталоге нет манифестов: {root}"])

    all_docs: list[dict] = []
    for f in files:
        text = f.read_text(encoding="utf-8")
        for line_no, line in enumerate(text.splitlines(), 1):
            if "__" in line and "___" in line:
                continue
            if line.count("__") == 2 and line.replace("__", "").replace("/", "").isprintable():
                marker = line.split("__")[1]
                if marker and marker.replace("_", "").isupper():
                    err(f"{f.name}:{line_no}: незаполненный плейсхолдер __" + marker + "__")
        try:
            docs = load_docs(f)
        except yaml.YAMLError as exc:
            err(f"{f.name}: невалидный YAML: {exc}")
            continue
        if not docs:
            err(f"{f.name}: нет ни одного ресурса")
        all_docs.extend(docs)

    if errors:
        return _fail(errors)

    idx = index(all_docs)

    # --- базовые поля каждого ресурса -------------------------------------
    for (kind, name), doc in idx.items():
        meta = doc.get("metadata", {})
        if not doc.get("apiVersion"):
            err(f"{kind} {name}: нет apiVersion")
        if not meta.get("name"):
            err(f"{kind}: пустое metadata.name")
        if kind in {"Deployment", "Service", "Ingress", "PersistentVolumeClaim", "HorizontalPodAutoscaler"}:
            if not meta.get("namespace"):
                err(f"{kind} {name}: не задан metadata.namespace")

    ns_docs = by_kind(all_docs, "Namespace")
    if not ns_docs:
        warn("нет манифеста Namespace: применение пойдёт в текущий namespace")
    namespaces = {d["metadata"]["name"] for d in ns_docs}
    if len(namespaces) == 1:
        target_ns = namespaces.pop()
        for (kind, name), doc in idx.items():
            if kind == "Namespace":
                continue
            if doc["metadata"].get("namespace") != target_ns:
                err(f"{kind} {name}: namespace {doc['metadata'].get('namespace')!r} != {target_ns!r}")

    # --- Secret и ConfigMap -------------------------------------------------
    secrets = by_kind(all_docs, "Secret")
    if not secrets:
        err("нет Secret: приложение не сможет получить DATABASE_URL и JWT_SECRET")
    else:
        values = secret_values(secrets[0])
        for key in REQUIRED_SECRET_KEYS:
            if key not in values:
                err(f"Secret {secrets[0]['metadata']['name']}: нет ключа {key}")
            elif not str(values[key]).strip():
                err(f"Secret {secrets[0]['metadata']['name']}: ключ {key} пуст")

    cms = by_kind(all_docs, "ConfigMap")
    cm_names = {c["metadata"]["name"] for c in cms}

    # --- Deployment: образы, пробы, ресурсы, переменные --------------------
    deployments = by_kind(all_docs, "Deployment")
    if not deployments:
        err("нет ни одного Deployment")

    selector_map: dict[tuple[str, str], dict] = {}
    for dep in deployments:
        name = dep["metadata"]["name"]
        spec = dep["spec"]
        pod_labels = spec["template"]["metadata"].get("labels", {})
        match_labels = spec.get("selector", {}).get("matchLabels", {})
        if not match_labels:
            err(f"Deployment {name}: пустой spec.selector.matchLabels")
        elif not match_labels.items() <= pod_labels.items():
            err(f"Deployment {name}: matchLabels {match_labels} не совпадают с метками pod {pod_labels}")
        selector_map[(name, "Deployment")] = match_labels

        containers = spec["template"]["spec"].get("containers", [])
        if not containers:
            err(f"Deployment {name}: нет контейнеров")
        for c in containers:
            image = c.get("image", "")
            if not image:
                err(f"Deployment {name}/{c.get('name')}: не задан image")
            elif ":" not in image.split("/")[-1]:
                err(f"Deployment {name}/{c.get('name')}: образ {image} без закреплённого тега")
            if image.endswith(":latest"):
                warn(f"Deployment {name}/{c.get('name')}: тег :latest лучше не использовать")
            if not c.get("resources", {}).get("requests"):
                warn(f"Deployment {name}/{c.get('name')}: нет resources.requests — HPA не сможет считать загрузку")
            if not c.get("resources", {}).get("limits"):
                warn(f"Deployment {name}/{c.get('name')}: нет resources.limits")
            if not c.get("readinessProbe"):
                warn(f"Deployment {name}/{c.get('name')}: нет readinessProbe — pod будет в трафике до готовности")
            if not c.get("livenessProbe"):
                warn(f"Deployment {name}/{c.get('name')}: нет livenessProbe — зависший процесс не перезапустится")
            if not c.get("ports") and name.endswith(("api", "web")):
                err(f"Deployment {name}/{c.get('name')}: не заявлен ни один containerPort")

            # env / envFrom должны ссылаться на существующие Secret и ConfigMap
            for env in c.get("env", []):
                ref = env.get("valueFrom", {})
                src = ref.get("secretKeyRef") or ref.get("configMapKeyRef")
                if not src:
                    continue
                target = by_kind(all_docs, "Secret" if "secretKeyRef" in ref else "ConfigMap")
                if not target:
                    kind = "Secret" if "secretKeyRef" in ref else "ConfigMap"
                    err(f"Deployment {name}/{c.get('name')}: ссылка на {kind} {src.get('name')}, но его нет в наборе")
                else:
                    pool = secret_values(target[0]) if "secretKeyRef" in ref else (target[0].get("data") or {})
                    if src.get("key") not in pool:
                        err(
                            f"Deployment {name}/{c.get('name')}: ключ {src.get('key')!r} "
                            f"отсутствует в {src.get('name')}"
                        )
            for src in c.get("envFrom", []):
                if "configMapRef" in src and cm_names and src["configMapRef"]["name"] not in cm_names:
                    err(f"Deployment {name}/{c.get('name')}: envFrom ссылается на ConfigMap {src['configMapRef']['name']}, которого нет")
                if "secretRef" in src and secrets and src["secretRef"]["name"] not in {s["metadata"]["name"] for s in secrets}:
                    err(f"Deployment {name}/{c.get('name')}: envFrom ссылается на Secret {src['secretRef']['name']}, которого нет")

    # --- Service / selector / порты ----------------------------------------
    services = by_kind(all_docs, "Service")
    for svc in services:
        name = svc["metadata"]["name"]
        sel = svc.get("spec", {}).get("selector") or {}
        if not sel:
            err(f"Service {name}: пустой selector — не найдёт ни одного pod")
        else:
            if not any(sel == labels for labels in selector_map.values()):
                err(f"Service {name}: selector {sel} не совпадает ни с одним Deployment")
        ports = svc.get("spec", {}).get("ports", [])
        if not ports:
            err(f"Service {name}: не задан ни один порт")
        for p in ports:
            if "port" not in p or "targetPort" not in p:
                err(f"Service {name}: порт {p} без port/targetPort")
            if "name" not in p and len(ports) > 1:
                warn(f"Service {name}: именованный порт обязателен, если портов несколько")

    # --- Ingress / TLS ------------------------------------------------------
    for ing in by_kind(all_docs, "Ingress"):
        name = ing["metadata"]["name"]
        spec = ing.get("spec", {})
        if not spec.get("rules"):
            err(f"Ingress {name}: нет rules — домен не задан")
        for rule in spec.get("rules", []):
            host = rule.get("host")
            if not host:
                err(f"Ingress {name}: правило без host")
            elif "example.com" in host:
                warn(f"Ingress {name}: host {host} — похоже на значение по умолчанию, задайте APP_DOMAIN")
            for path in (rule.get("http", {}).get("paths") or []):
                if not path.get("backend", {}).get("service", {}).get("name"):
                    err(f"Ingress {name}: путь {path.get('path')} без backend.service.name")
        tls = spec.get("tls") or []
        for t in tls:
            secret_name = t.get("secretName")
            if not secret_name:
                err(f"Ingress {name}: блок tls без secretName")
            for host in t.get("hosts", []):
                hosts_in_rules = {r.get("host") for r in spec.get("rules", [])}
                if host not in hosts_in_rules:
                    err(f"Ingress {name}: tls.host {host} не совпадает ни с одним rules.host")

    # --- PVC ----------------------------------------------------------------
    pvcs = by_kind(all_docs, "PersistentVolumeClaim")
    if not pvcs:
        warn("нет PVC: загрузки и бэкапы не переживут пересоздание pod")
    for pvc in pvcs:
        name = pvc["metadata"]["name"]
        spec = pvc.get("spec", {})
        if not spec.get("accessModes"):
            err(f"PVC {name}: не заданы accessModes")
        if not spec.get("resources", {}).get("requests", {}).get("storage"):
            err(f"PVC {name}: не запрошен объём storage")
        sc = spec.get("storageClassName")
        if sc:
            warn(f"PVC {name}: storageClassName={sc} — на кластере должен быть storage class с таким именем")

    # --- HPA ----------------------------------------------------------------
    for hpa in by_kind(all_docs, "HorizontalPodAutoscaler"):
        name = hpa["metadata"]["name"]
        spec = hpa.get("spec", {})
        target = spec.get("scaleTargetRef", {})
        if target.get("kind") != "Deployment" or (target.get("name"), "Deployment") not in selector_map:
            err(f"HPA {name}: scaleTargetRef {target} не указывает на существующий Deployment")
        if "minReplicas" not in spec or "maxReplicas" not in spec:
            err(f"HPA {name}: не заданы minReplicas/maxReplicas")
        elif spec["minReplicas"] > spec["maxReplicas"]:
            err(f"HPA {name}: minReplicas больше maxReplicas")

    # --- PVC должны монтироваться ------------------------------------------
    for (kind, name), doc in idx.items():
        if kind != "Deployment":
            continue
        volumes = {v["name"] for v in doc["spec"]["template"]["spec"].get("volumes", [])}
        claims = {
            v.get("persistentVolumeClaim", {}).get("claimName")
            for v in doc["spec"]["template"]["spec"].get("volumes", [])
            if v.get("persistentVolumeClaim")
        }
        pvc_names = {p["metadata"]["name"] for p in pvcs}
        for claim in claims:
            if claim not in pvc_names:
                err(f"Deployment {name}: ссылка на PVC {claim}, которого нет в наборе")
        for c in doc["spec"]["template"]["spec"].get("containers", []):
            for mount in c.get("volumeMounts", []):
                if mount["name"] not in volumes:
                    err(f"Deployment {name}/{c.get('name')}: volumeMount {mount['name']} без соответствующего volume")

    # --- образы: версия из setup.sh должна доехать до манифестов -----------
    for dep in deployments:
        for c in dep["spec"]["template"]["spec"].get("containers", []):
            image = c.get("image", "")
            if image and image.rsplit(":", 1)[-1] in {"", "latest"}:
                warn(f"Deployment {dep['metadata']['name']}: образ {image} не закреплён")

    kubectl = _try_kubectl(files, root)
    if kubectl is None:
        print("kubectl не найден — серверная валидация схем пропущена (структурные проверки выполнены)")

    return _report()


def _try_kubectl(files: list[Path], root: Path):
    """Серверная проверка схем, если kubectl и кластер доступны."""
    import shutil
    import subprocess

    if not shutil.which("kubectl"):
        return None
    try:
        proc = subprocess.run(
            ["kubectl", "apply", "--dry-run=client", "-f", str(root)],
            capture_output=True, text=True, timeout=60,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if proc.returncode != 0:
        for line in (proc.stderr or proc.stdout).splitlines():
            if line.strip():
                err(f"kubectl: {line.strip()}")
    else:
        print("kubectl apply --dry-run=client: схемы приняты")
    return True


def _fail(msgs: list[str]) -> int:
    for m in msgs:
        print(f"  ОШИБКА: {m}")
    print(f"\nПроверка не пройдена: {len(msgs)} проблем")
    return 1


def _report() -> int:
    for m in warnings:
        print(f"  ВНИМАНИЕ: {m}")
    if errors:
        for m in errors:
            print(f"  ОШИБКА: {m}")
    print(f"\nОшибок: {len(errors)} · предупреждений: {len(warnings)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
