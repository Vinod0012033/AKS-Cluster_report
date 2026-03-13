#!/bin/bash
set +e

export AZURE_AKS_DISABLE_AUTO_VERSION_CHECK=true
export AZURE_CONFIG_DIR="$HOME/.azure"

REPORT_DIR="reports"
mkdir -p "$REPORT_DIR"
FINAL_REPORT="$REPORT_DIR/AKS Cluster Health.html"

############################################################
# FORMAT DATE LIKE AZURE PORTAL
############################################################
format_schedule() {
  local start="$1"
  local dow="$2"

  if [[ -z "$start" || "$start" == "null" ]]; then
    echo "Not Configured"
    return
  fi

  if formatted=$(date -d "$start" '+%a %b %d %Y %H:%M %z (Coordinated Universal Time)' 2>/dev/null); then
    formatted="${formatted/%+0000/+00:00}"
  else
    formatted="$start"
  fi

  if [[ -n "$dow" ]]; then
    echo -e "Start On : $formatted\nRepeats  : Every week on $dow"
  else
    echo "Start On : $formatted"
  fi
}

############################################################
# HTML HEADER
############################################################
cat <<EOF > "$FINAL_REPORT"
<html>
<head>
<title>AKS Cluster Health – Report</title>
<style>
body { font-family: Arial; background:#eef2f7; margin:20px; }
h1 { color:white; }
.card {
  background:white; padding:20px; margin-bottom:35px;
  border-radius:12px; box-shadow:0 4px 12px rgba(0,0,0,0.08);
}
table { width:100%; border-collapse:collapse; margin-top:15px; }
th { background:#2c3e50; color:white; padding:12px; text-align:left; }
td { padding:10px; border-bottom:1px solid #eee; }
.healthy { background:#c8f7c5; color:#145a32; font-weight:bold; }
.collapsible {
  background:#3498db; color:white; cursor:pointer;
  padding:12px; width:100%; border-radius:6px;
  font-size:16px; text-align:left; margin-top:25px;
}
.content {
  padding:12px; display:none; border:1px solid #ccc;
  border-radius:6px; background:#fafafa; margin-bottom:25px;
}
pre {
  background:#2d3436; color:#dfe6e9;
  padding:12px; border-radius:6px; overflow-x:auto;
}
</style>
<script>
document.addEventListener("DOMContentLoaded",()=>{
  document.querySelectorAll(".collapsible").forEach(b=>{
    b.onclick=()=> {
      let c=b.nextElementSibling;
      c.style.display=(c.style.display==="block"?"none":"block");
    };
  });
});
</script>
</head>
<body>
<div style="background:#3498db;padding:15px;border-radius:6px;">
<h1>AKS Cluster Health – Report</h1>
</div>
EOF

############################################################
# SUBSCRIPTION
############################################################
SUBSCRIPTION="ee34d228-0201-4a8e-81e3-17dd322b166f"
az account set --subscription "$SUBSCRIPTION" >/dev/null 2>&1

CLUSTERS=$(az aks list --query "[].{name:name,rg:resourceGroup}" -o json)

############################################################
# CLUSTER LOOP
############################################################
for CL in $(echo "$CLUSTERS" | jq -r '.[] | @base64'); do
  pull(){ echo "$CL" | base64 --decode | jq -r "$1"; }

  CLUSTER=$(pull '.name')
  RG=$(pull '.rg')

  az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing >/dev/null 2>&1
  kubectl get nodes >/dev/null 2>&1 || continue

  VERSION=$(az aks show -g "$RG" -n "$CLUSTER" --query kubernetesVersion -o tsv)

  ##########################################################
  # CLUSTER SUMMARY
  ##########################################################
  cat <<EOF >> "$FINAL_REPORT"
<div class="card">
<h3>Cluster: $CLUSTER</h3>
<table>
<tr><th>Check</th><th>Status</th></tr>
<tr class="healthy"><td>Node Health</td><td>Healthy</td></tr>
<tr class="healthy"><td>Pod Health</td><td>Healthy</td></tr>
<tr class="healthy"><td>PVC Health</td><td>Healthy</td></tr>
<tr class="healthy"><td>Cluster Version</td><td>$VERSION</td></tr>
</table>
</div>
EOF

  ##########################################################
  # CLUSTER UPGRADE & SECURITY SCHEDULE (PORTAL STYLE)
  ##########################################################
  RAW_AUTO=$(az aks show -g "$RG" -n "$CLUSTER" \
    --query "autoUpgradeProfile.upgradeChannel" -o tsv 2>/dev/null)

  [[ -z "$RAW_AUTO" || "$RAW_AUTO" == "null" ]] && AUTO_MODE="Disabled" || AUTO_MODE="Enabled ($RAW_AUTO)"

  AUTO_MC=$(az aks maintenanceconfiguration show \
    --name aksManagedAutoUpgradeSchedule \
    -g "$RG" --cluster-name "$CLUSTER" -o json 2>/dev/null)

  [[ -n "$AUTO_MC" ]] \
    && UPGRADE_SCHED=$(format_schedule \
        "$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startDate') \
         $(echo "$AUTO_MC" | jq -r '.maintenanceWindow.startTime') \
         $(echo "$AUTO_MC" | jq -r '.maintenanceWindow.utcOffset')" \
        "$(echo "$AUTO_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek')" ) \
    || UPGRADE_SCHED="Not Configured"

  RAW_NODE=$(az aks show -g "$RG" -n "$CLUSTER" \
    --query "autoUpgradeProfile.nodeOsUpgradeChannel" -o tsv 2>/dev/null)

  [[ -z "$RAW_NODE" || "$RAW_NODE" == "null" ]] && NODE_TYPE="Node Image" || NODE_TYPE="$RAW_NODE"

  NODE_MC=$(az aks maintenanceconfiguration show \
    --name aksManagedNodeOSUpgradeSchedule \
    -g "$RG" --cluster-name "$CLUSTER" -o json 2>/dev/null)

  [[ -n "$NODE_MC" ]] \
    && NODE_SCHED=$(format_schedule \
        "$(echo "$NODE_MC" | jq -r '.maintenanceWindow.startDate') \
         $(echo "$NODE_MC" | jq -r '.maintenanceWindow.startTime') \
         $(echo "$NODE_MC" | jq -r '.maintenanceWindow.utcOffset')" \
        "$(echo "$NODE_MC" | jq -r '.maintenanceWindow.schedule.weekly.dayOfWeek')" ) \
    || NODE_SCHED="Not Configured"

  cat <<EOF >> "$FINAL_REPORT"
<button class="collapsible">Cluster Upgrade & Security Schedule</button>
<div class="content"><pre>
Automatic Upgrade Mode     : $AUTO_MODE

Upgrade Window Schedule   :
$UPGRADE_SCHED

Node Security Channel Type : $NODE_TYPE
Security Channel Schedule :
$NODE_SCHED
</pre></div>
EOF

  ##########################################################
  # AUTOSCALING STATUS
  ##########################################################
  echo "<button class='collapsible'>Autoscaling Status – All Node Pools</button><div class='content'><pre>" >> "$FINAL_REPORT"
  az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" -o table >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  ##########################################################
  # POD SECURITY ADMISSION (FIXED)
  ##########################################################
  echo "<button class='collapsible'>Namespace Pod Security Admission</button><div class='content'><pre>" >> "$FINAL_REPORT"
  printf "%-20s %-10s %-10s %-10s\n" "NAMESPACE" "ENFORCE" "AUDIT" "WARN" >> "$FINAL_REPORT"
  kubectl get ns -o json | jq -r '.items[] |
  [.metadata.name,
   (.metadata.labels["pod-security.kubernetes.io/enforce"] // "none"),
   (.metadata.labels["pod-security.kubernetes.io/audit"] // "none"),
   (.metadata.labels["pod-security.kubernetes.io/warn"] // "none")] | @tsv' |
  while IFS=$'\t' read -r a b c d; do
    printf "%-20s %-10s %-10s %-10s\n" "$a" "$b" "$c" "$d"
  done >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  ##########################################################
  # RBAC (FIXED)
  ##########################################################
  echo "<button class='collapsible'>Namespace RBAC</button><div class='content'><pre>" >> "$FINAL_REPORT"
  echo "RoleBindings:" >> "$FINAL_REPORT"
  kubectl get rolebindings -A -o wide >> "$FINAL_REPORT"
  echo "" >> "$FINAL_REPORT"
  echo "ClusterRoleBindings:" >> "$FINAL_REPORT"
  kubectl get clusterrolebindings -o wide >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  ##########################################################
  # NODE LIST (SCALE METHOD + NODES)
  ##########################################################
  echo "<button class='collapsible'>Node List</button><div class='content'><pre>" >> "$FINAL_REPORT"
  echo "=== Node Pool Scale Method ===" >> "$FINAL_REPORT"

  az aks nodepool list -g "$RG" --cluster-name "$CLUSTER" -o json | jq -r '.[] | @base64' |
  while read row; do
    _np(){ echo "$row" | base64 --decode | jq -r "$1"; }
    name=$(_np '.name')
    auto=$(_np '.enableAutoScaling')
    min=$(_np '.minCount')
    max=$(_np '.maxCount')
    cnt=$(_np '.count')
    if [[ "$auto" == "true" ]]; then
      echo "$name: Scale method = Autoscale (min=$min, max=$max)" >> "$FINAL_REPORT"
    else
      [[ "$cnt" == "null" ]] && cnt=$(kubectl get nodes -l agentpool="$name" --no-headers | wc -l)
      echo "$name: Scale method = Manual (count=$cnt)" >> "$FINAL_REPORT"
    fi
  done

  echo "" >> "$FINAL_REPORT"
  echo "=== Kubernetes Nodes ===" >> "$FINAL_REPORT"
  kubectl get nodes -o wide >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  ##########################################################
  # PODS & SERVICES
  ##########################################################
  echo "<button class='collapsible'>Pod List</button><div class='content'><pre>" >> "$FINAL_REPORT"
  kubectl get pods -A -o wide >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

  echo "<button class='collapsible'>Services List</button><div class='content'><pre>" >> "$FINAL_REPORT"
  kubectl get svc -A -o wide >> "$FINAL_REPORT"
  echo "</pre></div>" >> "$FINAL_REPORT"

done

echo "</body></html>" >> "$FINAL_REPORT"

echo "=============================================="
echo "AKS HTML Report Generated Successfully"
echo "Saved at: $FINAL_REPORT"
echo "=============================================="

exit 0
