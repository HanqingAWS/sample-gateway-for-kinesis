#!/bin/bash
set -euo pipefail

# Accuracy test: send full 28-field request, read from Kinesis, compare
# Usage: ./scripts/test-accuracy.sh <NLB_DNS> [STREAM_NAME] [REGION]

NLB_DNS="${1:?Usage: $0 <NLB_DNS> [STREAM_NAME] [REGION]}"
STREAM="${2:-guangdiantong_attribution_event}"
REGION="${3:-ap-northeast-1}"

echo "=== Sending test request to ${NLB_DNS} ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -G "http://${NLB_DNS}/test" \
  --data-urlencode "account_id=72168517" \
  --data-urlencode "ad_platform_type=1" \
  --data-urlencode "ad_type=1" \
  --data-urlencode "agency_id=17917417" \
  --data-urlencode "app_id=gof.cn.prod" \
  --data-urlencode "bi_os=wechat" \
  --data-urlencode 'callback=https://api.e.qq.com/v3.0/user_actions/add?cb=c4UzpmhCu1j7bbw4g2rH8q4GLo4D_r6ZANcYl7OJd6lnTJIghSNeA2bZtU52Nmd6&conv_id=68143750' \
  --data-urlencode "channel=guangdiantong_wechat_recall" \
  --data-urlencode "click_id=wxadclickggfwtspmsyivd" \
  --data-urlencode "click_time=1774942356" \
  --data-urlencode 'creative_components_info=[{"id":56115185184,"type":"DESCRIPTION"},{"id":56115715583,"type":"VIDEO"},{"id":55084977074,"type":"ACTION_BUTTON"},{"id":55084975713,"type":"BRAND"},{"id":55084982542,"type":"JUMP_INFO"},{"id":55084980565,"type":"TEXT_LINK"}]' \
  --data-urlencode "creative_id=6611920057" \
  --data-urlencode "creative_name=GOFCN42366_玩法_资源城建_解说_都说了家里没人_小程序_横版_play_1769260275126" \
  --data-urlencode "csite=SITE_SET_SMART" \
  --data-urlencode 'element_info=[{"id":"28831249729","type":"IMAGE"},{"id":"28831251354","type":"VIDEO"},{"id":"28431957458","type":"IMAGE"}]' \
  --data-urlencode "match_id=wx0w3zxx7st24kmk00" \
  --data-urlencode "promoted_object_id=wxada4175c8b2a9864" \
  --data-urlencode "promoted_object_type=46" \
  --data-urlencode "request_id=wx0w3zxx7st24kmk" \
  --data-urlencode "adgroup_id=29831567842" \
  --data-urlencode "adgroup_name=GOFCN42366_玩法_资源城建_解说_小程序_横版_auto" \
  --data-urlencode "campaign_id=18934521076" \
  --data-urlencode "campaign_name=GOFCN_WX_RECALL_ROI7_PLAY" \
  --data-urlencode "site_id=2000000246" \
  --data-urlencode "impression_time=1774942350" \
  --data-urlencode "model_id=0" \
  --data-urlencode "adcreative_id=6611920057" \
  --data-urlencode "page_id=0" \
  --data-urlencode "display_scene=" \
  --data-urlencode "conv_id=68143750")

echo "HTTP Response Code: ${HTTP_CODE}"
if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: Expected HTTP 200, got ${HTTP_CODE}"
  exit 1
fi

echo "=== Waiting 5s for Kinesis write ==="
sleep 5

echo "=== Reading from Kinesis stream: ${STREAM} ==="
SHARD_ID=$(aws kinesis list-shards --stream-name "$STREAM" --region "$REGION" \
  --query 'Shards[0].ShardId' --output text)

ITERATOR=$(aws kinesis get-shard-iterator \
  --stream-name "$STREAM" \
  --shard-id "$SHARD_ID" \
  --shard-iterator-type TRIM_HORIZON \
  --region "$REGION" \
  --query 'ShardIterator' --output text)

RECORDS=$(aws kinesis get-records --shard-iterator "$ITERATOR" --region "$REGION" --limit 10)

echo "=== Latest Kinesis Records ==="
echo "$RECORDS" | python3 -c "
import json, sys, base64
data = json.load(sys.stdin)
records = data.get('Records', [])
print(f'Total records found: {len(records)}')
if records:
    # Show the last record (most recent)
    last = records[-1]
    payload = base64.b64decode(last['Data']).decode('utf-8')
    parsed = json.loads(payload)
    print(f'Fields count: {len(parsed)}')
    print(json.dumps(parsed, indent=2, ensure_ascii=False))

    # Verify expected fields
    expected_fields = [
        'account_id', 'ad_platform_type', 'ad_type', 'adcreative_id',
        'adgroup_id', 'adgroup_name', 'agency_id', 'app_id', 'bi_os',
        'callback', 'campaign_id', 'campaign_name', 'channel', 'click_id',
        'click_time', 'conv_id', 'creative_components_info', 'creative_id',
        'creative_name', 'csite', 'display_scene', 'element_info',
        'impression_time', 'match_id', 'model_id', 'page_id',
        'promoted_object_id', 'promoted_object_type', 'request_id', 'site_id'
    ]
    missing = [f for f in expected_fields if f not in parsed]
    extra = [f for f in parsed if f not in expected_fields]
    if missing:
        print(f'MISSING fields: {missing}')
    if extra:
        print(f'EXTRA fields: {extra}')
    if not missing and not extra:
        print(f'PASS: All {len(expected_fields)} expected fields present, no extra fields')
else:
    print('WARNING: No records found in stream')
"
