import sys
import os

def read_jpeg_chunks(filename):
    with open(filename, 'rb') as file:
        content = file.read()

    i = 0
    chunks = []

    while i < len(content) - 1:
        if content[i] == 0xFF:
            marker = content[i + 1]
            i += 2
            if marker == 0xD8 or marker == 0xD9:
                chunks.append((hex(marker), None))
            else:
                length = int.from_bytes(content[i:i + 2], 'big')
                chunk_content = content[i + 2:i + 2 + length - 2]
                chunks.append((hex(marker), chunk_content))
                i += length
        else:
            i += 1

    return chunks

chunks = read_jpeg_chunks(sys.argv[1])

for index, chunk in enumerate(chunks):
    print(f"Chunk {index + 1}: Marker {chunk[0]}, Größe des Inhalts: {len(chunk[1]) if chunk[1] else 'N/A'}")

