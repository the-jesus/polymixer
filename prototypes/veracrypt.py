import os
import sys
from hashlib import pbkdf2_hmac
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from twofish import Twofish

def hexdump(data, length=16):
    result = []
    for i in range(0, len(data), length):
        chunk = data[i:i+length]
        hex_part = ' '.join(f'{byte:02x}' for byte in chunk)
        ascii_part = ''.join((chr(byte) if 32 <= byte <= 126 else '.') for byte in chunk)
        result.append(f'{i:08x}  {hex_part:<{length*3}}  {ascii_part}')
    return '\n'.join(result)

def create_cipher(alg, key, iv):
    if alg == 'AES-256':
        return Cipher(algorithms.AES(key), modes.XTS(iv), backend=default_backend())
    elif alg == 'Serpent':
        return Cipher(algorithms.Serpent(key), modes.XTS(iv), backend=default_backend())
    elif alg == 'Twofish':
        return Cipher(algorithms.Twofish(key), modes.XTS(iv), backend=default_backend())
    elif alg == 'Camellia':
        return Cipher(algorithms.Camellia(key), modes.XTS(iv), backend=default_backend())
    else:
        raise ValueError("Unsupported algorithm")

def decrypt(alg, key, iv, data):
    if alg == 'AES-256':
        cipher = Cipher(algorithms.AES(key), modes.XTS(iv), backend=default_backend())
        return cipher.decryptor().update(data) + cipher.decryptor().finalize()
    elif alg == 'Twofish':
        cipher = Twofish(key[:32])
        return cipher.decrypt(data[:16])
    elif alg == 'Twofish2':
        cipher = Twofish(key[32:])
        return cipher.decrypt(data[:16])
    elif alg == 'Camellia':
        cipher = Cipher(algorithms.Camellia(key[:32]), modes.XTS(iv), backend=default_backend())
        return cipher.decryptor().update(data) + cipher.decryptor().finalize()

def encrypt_decrypt(data, password, salt, alg, prf, pim=None, encrypt=True):
    iterations = 500000 if pim is None else 1000 * pim
    #iterations = 2000 if pim is None else 1000 * pim
    key = pbkdf2_hmac(prf.lower().replace('-', ''), password.encode(), salt, iterations, 64)
    iv = b'\x00' * 16

    return decrypt(alg, key, iv, data)

    #cipher = create_cipher(alg, key, iv)
    #if encrypt:
    #    return cipher.encryptor().update(data) + cipher.encryptor().finalize()
    #else:
    #    return cipher.decryptor().update(data) + cipher.decryptor().finalize()

with open(sys.argv[1], 'rb') as file:
    salt = file.read(64)
    #data = file.read(448)
    data = file.read(16)

password = 'test'

prfs = [
    'SHA-512',
    'SHA-256',
    'BLAKE2S-256',
    'RIPE-MD-160',
    #'Whirlpool',
]

algs = [
    'AES-256',
    #'Serpent',
    'Twofish',
    'Twofish2',
    'Camellia',
]

#encrypted_data = encrypt_decrypt(data, password, salt, alg, prf, encrypt=True)

for alg in algs:
    for prf in prfs:
        print(prf)

        decrypted_data = encrypt_decrypt(data, password, salt, alg, prf, encrypt=False)
        print(hexdump(decrypted_data))
        print()

#assert decrypted_data == data  # Sicherstellen, dass Verschlüsselung korrekt funktioniert
