# Создать conda-окружение с Python 3.11
conda create -n glmocr python=3.11
conda activate glmocr

# Установить PyTorch с CUDA 11.8 (подходит для RTX 2070)
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu118

# Проверить GPU
python -c "import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0))"



$IP   = "117.18.102.48"
$PORT = "41560"
# Create remote dir
ssh -p $PORT root@$IP "mkdir -p /root/services/glmocr-401k"
# Copy files
scp -P $PORT `
  "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\app.py" `
  "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\config.selfhosted.yaml" `
  "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\requirements.txt" `
  "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\deploy.sh" `
  "root@${IP}:/root/services/glmocr-401k/"




scp -P 39433 "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\app.py" root@117.18.102.42:/root/services/glmocr-401k/
scp -P 39433 "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\config.selfhosted.yaml" root@117.18.102.42:/root/services/glmocr-401k/
scp -P 39433 "D:\Work\ML\GLM-OCR\services\glmocr_401k_service\requirements.txt" root@117.18.102.42:/root/services/glmocr-401k/


scp -P 39433 "D:\Work\ML\GLM-OCR\TUNNELLCONSULTINGINC_434593.pdf" root@117.18.102.42:/root/services/glmocr-401k/

curl -X POST http://127.0.0.1:18001/parse-pdf \
  -F "file=@/root/services/glmocr-401k/MAGNETIKAINC.pdf" \
  -F "only_investment_tables=true" \
  -F "response_format=json"




scp -P 39433 root@117.18.102.42:/root/services/glmocr-401k/MAGNETIKAINC_tables.xlsx "D:\Work\ML\GLM-OCR\"



