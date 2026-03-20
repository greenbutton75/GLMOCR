# glm_ocr_direct.py
import torch
from transformers import AutoProcessor, AutoModelForImageTextToText
from PIL import Image

MODEL_PATH = "zai-org/GLM-OCR"

class GlmOcrDirect:
    def __init__(self):
        print("Загрузка GLM-OCR...")
        self.processor = AutoProcessor.from_pretrained(MODEL_PATH)
        self.model = AutoModelForImageTextToText.from_pretrained(
            MODEL_PATH,
            torch_dtype=torch.float16,
            device_map="cuda",
        )
        self.model.eval()
        print("Готово!")

    def parse_table(self, image: Image.Image) -> str:
        messages = [{
            "role": "user",
            "content": [
                {"type": "image", "url": image},  
                {"type": "text", "text": "Table Recognition:"}
            ]
        }]
        inputs = self.processor.apply_chat_template(
            messages, tokenize=True,
            add_generation_prompt=True,
            return_dict=True,
            return_tensors="pt"
        ).to("cuda")
        inputs.pop("token_type_ids", None)

        with torch.no_grad():
            generated_ids = self.model.generate(
                **inputs, max_new_tokens=4096
            )
        output = self.processor.decode(
            generated_ids[0][inputs["input_ids"].shape[1]:],
            skip_special_tokens=False
        )
        return output