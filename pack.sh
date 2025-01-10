#!/bin/bash

rm -rf /tmp/fapra

mkdir -p /tmp/fapra/fapra

rsync -a VeraCrypt-VeraCrypt_1.26.14 /tmp/fapra/fapra/

rsync -a chunk chunk_manager file_handler \
    hook_manager main.py module_registry \
    modules README.md requirements.txt \
    /tmp/fapra/fapra/

rsync -a samples/binary2.php samples/binary.php \
    samples/container.tc samples/fapra.zip samples/output.wav samples/test.sh \
    /tmp/fapra/fapra/samples/

make -C /tmp/fapra/fapra/VeraCrypt-VeraCrypt_1.26.14/src clean

rm -rf $(find /tmp/fapra -name __pycache__)

tar -czf /tmp/fapra.tgz -C /tmp/fapra fapra
