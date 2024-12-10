from file_handler import FileHandler
from typing import List

from modules.pdf import PDFHandler
from modules.zip import ZIPHandler

def get_handlers(file_path: str, handlers: List[FileHandler]):
    return [ handler for handler in handlers if handler.supports(file_path) ]

if __name__ == "__main__":
    handlers = [
        PDFHandler(),
        ZIPHandler(),
    ]

    files = ["example.pdf", "archive.zip"]

    for file in files:
        print(get_handlers(file, handlers))
