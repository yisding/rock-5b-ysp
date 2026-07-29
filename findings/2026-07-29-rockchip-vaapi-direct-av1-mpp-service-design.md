# A direct `/dev/mpp_service` AV1 backend can bypass libmpp by owning a surface-keyed VDPU job compiler

promoted → [video-libraries/vaapi/docs/av1-direct-mpp-service-backend.md](../video-libraries/vaapi/docs/av1-direct-mpp-service-backend.md) (2026-07-29)

The maintained design records the source-inspected kernel/libmpp boundary,
surface-keyed solution for the missing refresh mask, transferred HAL and
allocation responsibilities, security boundary, open discriminators, and
golden-job replay sequence. It remains DESIGN rather than hardware evidence.
