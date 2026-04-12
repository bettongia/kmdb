# Model downloader

To run the python aspects, make sure you'd in the project base dir and:

```
python -m venv .venv
source .venv/bin/activate

pip install "optimum[onnx]" onnx onnxruntime transformers

mkdir -p assets

optimum-cli export onnx \
    --model BAAI/bge-small-en-v1.5 \
    --task feature-extraction \
    assets/

mv assets/model.onnx assets/bge_small.onnx

python scripts/save_vocab.py
```
