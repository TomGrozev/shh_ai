# NER model is Bumblebee + bert-small-pii-detection

Neural PII detection runs locally using the `gravitee-io/bert-small-pii-detection` model (~110 MB) served via Bumblebee with NX/EXLA acceleration. This avoids sending sensitive text to an external PII API, keeps latency low, and supports 24 distinct PII entity types out of the box. The trade-off is a ~110 MB model download on first boot and CPU/GPU memory usage at runtime, which we accept in exchange for data-sovereignty and cost predictability.
