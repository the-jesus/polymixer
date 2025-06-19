from typing import List
from file_handler import FileHandler
from chunk import Chunk, FixedChunk, FlexibleChunk
from argparse import ArgumentParser
from hook_manager import HookManager
from chunk_manager import ChunkManager
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

class TruecryptHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager):
        self.header_chunk = None
        self.filepath = args.truecrypt_file
        self.reencrypt_key = args.truecrypt_new_salt
        self.vera = args.truecrypt_vera

        if self.reencrypt_key and not args.truecrypt_password:
            raise Exception("Password is required to re-encrypt the keys with a new salt")

        if self.reencrypt_key:
            self.password = args.truecrypt_password.encode()
            hook_manager.register('placing:complete', self.chunks_placed)

    def param(self, parser: ArgumentParser) -> None:
        truecrypt_group = parser.add_argument_group("TrueCrypt Options")
        truecrypt_group.add_argument("--truecrypt-file", nargs=None, help="Specify the source TrueCrypt container.", required=True)
        truecrypt_group.add_argument("--truecrypt-new-salt", action='store_true', help="Enables re-encryption of the key using the specified salt.")
        truecrypt_group.add_argument("--truecrypt-password", nargs=None, help="The password of the TrueCrypt container.")
        truecrypt_group.add_argument("--truecrypt-vera", action='store_true', help="Support verascript images")

    def chunks_placed(self, chunk_manager: ChunkManager) -> None:
        new_salt = chunk_manager[0:64]

        clear_header = self.decrypt_truecrypt_header(
            self.old_header,
            self.password,
            self.old_salt,
        )

        if clear_header == None:
            raise Exception("Could not find TrueCrypt header")

        new_header = self.encrypt_truecrypt_header(
            clear_header,
            self.password,
            new_salt,
        )

        self.header_chunk.data[64:512] = new_header

    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_COPY)
            image_size = f.seek(0, 2)

        header_size = 128 * 1024

        chunks = []

        self.old_salt = data[0:64]
        self.old_header = data[64:512]

        if self.reencrypt_key:
            self.header_chunk = FixedChunk(position=64, size=448, offset=64, data=data)
            chunks.append(self.header_chunk)
        else:
            chunks.append(FixedChunk(position=0, size=512, offset=0, data=data))

        chunks.append(FixedChunk(position=header_size, size=image_size - header_size, offset=header_size, data=data))

        return chunks

    def _get_cipher(self, password, salt, hash_algorithm):
        if self.vera:
            key = pbkdf2_hmac(hash_algorithm, password, salt, 500000, 64)
        else:
            key = pbkdf2_hmac(hash_algorithm, password, salt, 2000, 64)
        iv = b'\x00' * 16
        return Cipher(algorithms.AES(key), modes.XTS(iv), backend=default_backend())

    def decrypt_truecrypt_header(self, header, password, salt):
        for hash_algorithm in ['ripemd160', 'sha512']:
            xts_cipher = self._get_cipher(password, salt, hash_algorithm)
            cipher = xts_cipher.decryptor()
            decrypted_header = cipher.update(header) + cipher.finalize()

            if decrypted_header[0:4] in [ b'VERA', b'TRUE' ]:
                return decrypted_header

        return None

    def encrypt_truecrypt_header(self, header, password, new_salt):
        xts_cipher = self._get_cipher(password, new_salt, 'sha512')
        cipher = xts_cipher.encryptor()
        encrypted_header = cipher.update(header) + cipher.finalize()

        return encrypted_header
