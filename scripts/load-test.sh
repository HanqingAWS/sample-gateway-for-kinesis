#!/bin/bash
set -euo pipefail

# Load test using Apache Bench (AB) - dual process
# Reference: clickstream-lakehouse PERFORMANCE_TEST.md
# Usage: ./scripts/load-test.sh <NLB_DNS> [TOTAL_REQUESTS] [CONCURRENCY]

NLB_DNS="${1:?Usage: $0 <NLB_DNS> [TOTAL_REQUESTS] [CONCURRENCY]}"
TOTAL="${2:-1000000}"
CONCURRENCY="${3:-100}"
RESULTS_DIR="./load-test-results"

mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Install ab if not present
if ! command -v ab &> /dev/null; then
  echo "Installing Apache Bench..."
  sudo yum install -y httpd-tools 2>/dev/null || sudo apt-get install -y apache2-utils 2>/dev/null
fi

echo "============================================"
echo "Load Test Configuration"
echo "============================================"
echo "NLB:         ${NLB_DNS}"
echo "Requests:    ${TOTAL} per process (x2 processes)"
echo "Concurrency: ${CONCURRENCY} per process"
echo "Start time:  $(date)"
echo "============================================"

# URL with full query parameters (guangdiantong)
URL_GDT="http://${NLB_DNS}/guangdiantong?account_id=72168517&ad_platform_type=1&ad_type=1&agency_id=17917417&app_id=gof.cn.prod&bi_os=wechat&callback=https%3A%2F%2Fapi.e.qq.com%2Fv3.0%2Fuser_actions%2Fadd%3Fcb%3Dc4UzpmhCu1j7bbw4g2rH8q4GLo4D_r6ZANcYl7OJd6lnTJIghSNeA2bZtU52Nmd6%26conv_id%3D68143750&channel=guangdiantong_wechat_recall&click_id=wxadclickggfwtspmsyivd&click_time=1774942356&creative_id=6611920057&csite=SITE_SET_SMART&match_id=wx0w3zxx7st24kmk00&promoted_object_id=wxada4175c8b2a9864&promoted_object_type=46&request_id=wx0w3zxx7st24kmk&adgroup_id=29831567842&campaign_id=18934521076&site_id=2000000246&impression_time=1774942350&model_id=0&adcreative_id=6611920057&page_id=0&conv_id=68143750"

# URL with query parameters (toutiao)
URL_TT="http://${NLB_DNS}/toutiao?account_id=12345678&ad_platform_type=2&ad_type=1&click_id=toutiao_click_test_001&click_time=1774942356&creative_id=7890123456&campaign_id=19000000001&request_id=tt_req_001&match_id=tt_match_001&channel=toutiao_recall&app_id=gof.cn.prod&bi_os=android"

echo ""
echo "=== Starting dual-process load test ==="

# Process 1: guangdiantong
echo "Starting process 1 (guangdiantong)..."
ab -n "$TOTAL" -c "$CONCURRENCY" -r "$URL_GDT" > "${RESULTS_DIR}/ab_guangdiantong_${TIMESTAMP}.txt" 2>&1 &
PID1=$!

# Process 2: toutiao
echo "Starting process 2 (toutiao)..."
ab -n "$TOTAL" -c "$CONCURRENCY" -r "$URL_TT" > "${RESULTS_DIR}/ab_toutiao_${TIMESTAMP}.txt" 2>&1 &
PID2=$!

echo "Waiting for both processes (PID: ${PID1}, ${PID2})..."
wait $PID1 $PID2

echo ""
echo "============================================"
echo "Load Test Results"
echo "============================================"
echo ""
echo "--- guangdiantong ---"
grep -E "(Requests per second|Time per request|Failed requests|Non-2xx|Complete requests)" "${RESULTS_DIR}/ab_guangdiantong_${TIMESTAMP}.txt" || true
echo ""
echo "--- toutiao ---"
grep -E "(Requests per second|Time per request|Failed requests|Non-2xx|Complete requests)" "${RESULTS_DIR}/ab_toutiao_${TIMESTAMP}.txt" || true
echo ""
echo "End time: $(date)"
echo "Full results: ${RESULTS_DIR}/"
echo "============================================"
