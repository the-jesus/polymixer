#!/bin/bash

fsck.ext2 -f output.zip

echo

sudo mount -o loop output.zip /mnt
ls -al /mnt/
sudo umount /mnt

echo

dumpe2fs output.zip
