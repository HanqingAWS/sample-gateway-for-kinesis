# API Gateway to Kinesis - Project Notes

## Test Environment

- **Region**: ap-northeast-1
- **API Gateway**: `guangdiantong-attribution-api` (ID: `t0hirf9o49`)
- **Resource**: `/test` (GET)
- **Stage**: `prod`
- **Kinesis Stream**: `guangdiantong_attribution_event`
- **IAM Role**: `APIGatewayKinesisRole` (arn:aws:iam::044324713311:role/APIGatewayKinesisRole)
- **Endpoint**: `https://t0hirf9o49.execute-api.ap-northeast-1.amazonaws.com/prod/test`

## Production Reference

- **Production API ID**: `r0qaobt1ae`
- **Production Stream**: `ads_callback_kinesis_stream`
- Supports multiple ad platforms: guangdiantong (Tencent Ads) and toutiao (ByteDance)

## Integration Template

API Gateway 使用 VTL mapping template 将所有 query string 参数转为 JSON，base64 编码后通过 Kinesis PutRecord 写入。PartitionKey 使用 `$context.requestId`。

## Complete Test Request (guangdiantong/Tencent Ads)

```bash
curl -s -G "https://t0hirf9o49.execute-api.ap-northeast-1.amazonaws.com/prod/test" \
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
  --data-urlencode "conv_id=68143750"
```

## Kinesis Output (28 fields)

```json
{
    "account_id": "72168517",
    "ad_platform_type": "1",
    "ad_type": "1",
    "adcreative_id": "6611920057",
    "adgroup_id": "29831567842",
    "adgroup_name": "GOFCN42366_玩法_资源城建_解说_小程序_横版_auto",
    "agency_id": "17917417",
    "app_id": "gof.cn.prod",
    "bi_os": "wechat",
    "callback": "https://api.e.qq.com/v3.0/user_actions/add?cb=...&conv_id=68143750",
    "campaign_id": "18934521076",
    "campaign_name": "GOFCN_WX_RECALL_ROI7_PLAY",
    "channel": "guangdiantong_wechat_recall",
    "click_id": "wxadclickggfwtspmsyivd",
    "click_time": "1774942356",
    "conv_id": "68143750",
    "creative_components_info": "[JSON array - 6 elements]",
    "creative_id": "6611920057",
    "creative_name": "GOFCN42366_玩法_资源城建_解说_都说了家里没人_小程序_横版_play_1769260275126",
    "csite": "SITE_SET_SMART",
    "display_scene": "",
    "element_info": "[JSON array - 3 elements]",
    "impression_time": "1774942350",
    "match_id": "wx0w3zxx7st24kmk00",
    "model_id": "0",
    "page_id": "0",
    "promoted_object_id": "wxada4175c8b2a9864",
    "promoted_object_type": "46",
    "request_id": "wx0w3zxx7st24kmk",
    "site_id": "2000000246"
}
```

## Notes

- 生产日志中 query string 被截断 (TRUNCATED)，部分参数 (adgroup_id, campaign_id, site_id, impression_time 等) 基于广点通 API 常见字段补充
- 所有值在 Kinesis 中存储为字符串类型
- creative_components_info 和 element_info 作为 JSON 字符串存储（非嵌套对象）
- 中文以 Unicode 转义形式存储
- 测试验证时间: 2026-03-31
