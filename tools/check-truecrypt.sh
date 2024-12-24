#!/bin/bash

sudo zuluCrypt-cli -o -d output.zip -t tcrypt -p test
ls -la /run/media/private/*/output.zip
sudo umount /run/media/private/*/output.zip
sudo rmdir /run/media/private/*/output.zip
sudo fsck /dev/mapper/zuluCrypt-*-output.zip-*
sudo zuluCrypt-cli -q -d output.zip -t tcrypt -p test
