[LUKS with HTTPS unlock](https://tqdev.com/2023-luks-with-https-unlock)
-----------------------------------------------------

14 Jul 2023 - by 'Maurits van der Schee'

I feel that using full disk encryption of servers is a must. Not to protect against attacks with physical access (to the unencrypted boot loader or unprotected BIOS), but to avoid leaking data when a disk or computer is either stolen or replaced. But what do you do when you need to reboot your server and have no console access to enter the passphrase? This post will explain how you can make the server run a HTTPS request during the boot process to do automatic unlocking of the encrypted root partition over the Internet.

### Manual installation instructions

I have tested the below steps on Ubuntu 22.04 and these are expected to be correct for any recent Debian based distribution.

1) Install the "uuid" tool
```
sudo apt -y install uuid
```

2) Create a random key name using the "uuid" tool:
```
uuid
```
will show a random UUID, mine was:

    cdbafbaa-21d8-11ee-9186-df2d5ef43f21

3) Create a 256 byte key file with random data (.lek = LUKS Encryption Key):
```
dd if=/dev/urandom bs=1 count=256 > cdbafbaa-21d8-11ee-9186-df2d5ef43f21.lek
```

3a) Find your LUKS encrypted device:

    sudo lsblk -l --fs | grep crypto
    

Output for me is:

    nvme0n1p3         crypto_LUKS 2              eb571eb0-cff6-11ee-b5c9-fbde751daed9                  
    

3b) Check that you have a free slot:

    sudo cryptsetup luksDump /dev/nvme0n1p3
    

Output should contain slots like:

    Keyslots:
    

3c) Now add the encryption key to the last empty slot

    sudo cryptsetup luksAddKey /dev/nvme0n1p3 cdbafbaa-21d8-11ee-9186-df2d5ef43f21.lek
    

You need to enter an existing passphrase to add the key. Afterwards you can re-run the previous command to check that adding the key has succeeded.

4) Ensure that the packages "curl", "initramfs-tools", "dropbear-initramfs" are installed.
```
sudo apt -y install curl initramfs-tools dropbear-initramfs
```

Note that we install 'dropbear-initramfs' to ensure the network is configured.

5) Store the key on our "usbencryptionkey.com" webserver:
```
curl -f -s -F "keyfile=@cdbafbaa-21d8-11ee-9186-df2d5ef43f21.lek" \
    https://www.usbencryptionkey.com/register
```

6) Now create a hook to install the "curl" binary in the initramfs image.
```
sudo nano /usr/share/initramfs-tools/hooks/curl 
```

Paste the following content:

    #!/bin/sh -e
    PREREQS=""
    case $1 in
        prereqs) echo "${PREREQS}"; exit 0;;
    esac
    . /usr/share/initramfs-tools/hook-functions
    # copy curl binary
    copy_exec /usr/bin/curl /bin
    # fix DNS lib (needed for Debian 11)
    cp -a /usr/lib/x86_64-linux-gnu/libnss_dns* $DESTDIR/usr/lib/x86_64-linux-gnu/
    # fix DNS resolver (needed for Debian 11 + 12)
    echo "nameserver 1.1.1.1\n" > ${DESTDIR}/etc/resolv.conf
    # copy ca-certs for curl
    mkdir -p $DESTDIR/usr/share
    cp -ar /usr/share/ca-certificates $DESTDIR/usr/share/
    cp -ar /etc/ssl $DESTDIR/etc/
    

And ensure that the script is executable:

    sudo chmod 755 /usr/share/initramfs-tools/hooks/curl 
    

7) Now create the keyscript:
```
sudo nano /bin/luksunlockhttps
```

Paste the following content:

    #!/bin/sh -e
    # Wait 10 seconds for DHCP (needed for Debian 11+12)
    if [ $CRYPTTAB_TRIED -eq "0" ]; then
      sleep 10
    fi
    if curl -f --retry-connrefused --retry 5 -F "uuid=$CRYPTTAB_KEY" \
      https://www.usbencryptionkey.com/request; then
      exit
    fi
    /lib/cryptsetup/askpass "Enter password and press ENTER: "
    

Ensure that the keyscript is executable:

    sudo chmod 755 /bin/luksunlockhttps
    

8) Now modify the "crypttab" and replace "none luks" by "cdbafbaa-21d8-11ee-9186-df2d5ef43f21 luks,keyscript=/bin/luksunlockhttps" using:
```
sed -i 's/none luks/cdbafbaa-21d8-11ee-9186-df2d5ef43f21 luks,keyscript=\/bin\/luksunlockhttps/g' /etc/crypttab
```

9) Now regenerate the "initramfs" using:
```
sudo update-initramfs -u
```

Reboot and enjoy!

### Testing

I tested with the following installs:

*   Ubuntu 20.04 Server (ubuntu-20.04.6-live-server-amd64.iso)
*   Ubuntu 22.04 Server (ubuntu-22.04.2-live-server-amd64.iso)
*   Debian 11 (debian-11.5.0-amd64-netinst.iso)
*   Debian 12 (debian-12.0.0-amd64-netinst.iso)
*   Linux Mint 21.1 (linuxmint-21.1-xfce-64bit.iso)

This script is not yet ported to RockyLinux 8 & 9. Do you know about Dracut and want to contribute? Let me know at [maurits@vdschee.nl](mailto:maurits@vdschee.nl).

### The HTTPS backend

On the usbencryptionkey.com server the following HTTPS endpoints exist:

*   /register: upload a key file and whitelists the requesting IP address.
*   /request: requests key file using 'uuid' from a whitelisted IP address.

You can also download a shell install script that registers a new key and re-configures the boot, using:

    wget usbencryptionkey.com/install.sh
    

The usbencryptionkey.com service is not ready yet, but I have many plans for the service and the website. Note that you can easily implement you own service.

### Warning and disclaimer

The above commands modify the initramfs and errors could result in a system that does not boot. Although the commands do not delete your data it may be time consuming to restore access using a rescue image. If you have never updated initramfs from a chroot when booted from a rescue image then I suggested you [try that first](https://tqdev.com/2023-luks-recovery-from-initramfs-shell). And... make sure that you have backups of all your data.

### Clevis and Tang

If you want even better security you may consider a solution based on Clevis and Tang that enable automatic unlocking. Upside is that the unlocking server does not have the keys and the downside is that it is a more complex solution. Consider your threat model and decide what you want to use. Some interesting talks about the subject are here:

*   [Youtube: Clevis and Tang: securing your secrets at rest (RHEL)](https://www.youtube.com/watch?v=Dk6ZuydQt9I)
*   [Youtube: Clevis and tang overcoming the disk unlocking problem (Debian)](https://www.youtube.com/watch?v=v7caQEcB6VU)

### Related / Links

*   [TQdev.com: LUKS recovery from initramfs shell](https://tqdev.com/2023-luks-recovery-from-initramfs-shell)
*   [TQdev.com: LUKS with USB unlock](https://tqdev.com/2022-luks-with-usb-unlock)
*   [TQdev.com: LUKS with SSH unlock](https://tqdev.com/2022-luks-with-ssh-unlock)
*   [Dracut module that integrates the OpenSSH sshd into the initramfs](https://github.com/gsauthof/dracut-sshd)

Enjoy!

* * *

PS: Liked this article? Please share it [on Facebook,](https://www.facebook.com/sharer/sharer.php?u=https%3A%2F%2Ftqdev.com%2F2023-luks-with-https-unlock) [Twitter](https://twitter.com/intent/tweet?text=LUKS%20with%20HTTPS%20unlock...%20see%3A%20https%3A%2F%2Ftqdev.com%2F2023-luks-with-https-unlock) [or LinkedIn](https://www.linkedin.com/shareArticle?mini=true&url=https%3A%2F%2Ftqdev.com%2F2023-luks-with-https-unlock&title=LUKS%20with%20HTTPS%20unlock&summary=&source=).

* * *