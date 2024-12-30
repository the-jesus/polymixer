from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk, FlexibleChunk
from argparse import ArgumentParser
from hook_manager import HookManager
from chunk_manager import ChunkManager
import subprocess
import tempfile
import mmap

from hashlib import pbkdf2_hmac
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

def hexdump(data, length=16):
    result = []
    for i in range(0, len(data), length):
        chunk = data[i:i+length]
        hex_part = ' '.join(f'{byte:02x}' for byte in chunk)
        ascii_part = ''.join((chr(byte) if 32 <= byte <= 126 else '.') for byte in chunk)
        result.append(f'{i:08x}  {hex_part:<{length*3}}  {ascii_part}')

    return '\n'.join(result)

class VeracryptHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager):
        self.header_chunk = None
        self.filepath = args.veracrypt_file
        self.reencrypt_key = args.veracrypt_new_salt

        if self.reencrypt_key and not args.veracrypt_password:
            raise Exception("Password is required to re-encrypt the keys with a new salt")

        if self.reencrypt_key:
            self.password = args.veracrypt_password.encode()
            #hook_manager.register('placing:complete', self.chunks_placed)
            hook_manager.register('writing:finish', self.finish)

    def param(self, parser: ArgumentParser) -> None:
        veracrypt_group = parser.add_argument_group("VeraCrypt Options")
        veracrypt_group.add_argument("--veracrypt-file", nargs=None, help="Specify the source VeraCrypt container.", required=True)
        veracrypt_group.add_argument("--veracrypt-new-salt", action='store_true', help="Enables re-encryption of the key using the specified salt.")
        veracrypt_group.add_argument("--veracrypt-password", nargs=None, help="The password of the VeraCrypt container.")

    def finish(self, output_filename) -> None:
        print(output_filename)

        with open(output_filename, 'rb+') as file:
            new_salt = file.read(64)
            file.seek(0, 0)
            file.write(self.old_salt)

        #tmp = tempfile.NamedTemporaryFile(delete=True)
        tmp = tempfile.NamedTemporaryFile(delete=False)
        tmp.write(new_salt)

        password = self.password.decode()
        subprocess.run([
            'echo',
            './VeraCrypt-VeraCrypt_1.26.14/src/Main/veracrypt',
            '--text',
            '-v',
            f'--change',
            output_filename,
            f'--password={password}',
            f'--new-password={password}',
            f'--extsalt={tmp.name}',
            '--keyfiles=',
            '--pim=0',
            '--random-source=/dev/urandom',
            '--new-pim=0',
            '--new-keyfiles=',
        ])

    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_COPY)
            image_size = f.seek(0, 2)

        header_size = 64 * 1024
        container_position = 128 * 1024
        container_size = image_size - container_position * 2

        chunks = []

        self.old_salt = data[0:64]
        self.old_header = data[64:512]

        if self.reencrypt_key:
            self.header_chunk = FixedChunk(position=64, size=448, offset=64, data=data)
            chunks.append(self.header_chunk)
        else:
            chunks.append(FixedChunk(position=0, size=512, offset=0, data=data))

        chunks.append(FixedChunk(position=512, size=header_size - 512, offset=512, data=data))
        chunks.append(FixedChunk(position=container_position, size=container_size, offset=container_position, data=data))

        chunks.append(FixedChunk(position=-container_position, size=header_size, offset=image_size - container_position, data=data))

        return chunks
