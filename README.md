# Automatic decryption for LUKS encrypted root disks via webserver storage of encrypted LUKS keys

## Summary

Based off the great work here: [LUKS with HTTPS unlock](https://tqdev.com/2023-luks-with-https-unlock)

I wanted to extend this original work to also:

- Store the encryption keys on the webserver in an encrypted format so the webserver owner does not have your plaintext keys.
- Automate the installation of this methodology onto various Ubuntu and Debian alike OSes.

Like the original post, this is likely only valid for Ubuntu or Debian based OSes and I highly recommend taking backups of your new encryption key if you plan on removing your originial LUKS decryption method.

Note: The keys are expected to be provided at the root of the URL, e.g. ``https://mydomain.com/31e0d908-70a5-11ef-ad2e-76ac3383469b.lek.enc``


**Security hints:**

 - Ideally you would use a HTTPS enabled server as this will prevent other devices on the same network from being able to match the stored keys to a particular device.

 - Ideally your chosen web server has valid SSL certificates from a trusted vendor such as https://letsencrypt.org/

 - Ideally your chosen web server machine is highly hardened to attack e.g. Apparmor, SELinux and is only used for the singular purpose of hosting keys.

 - Ideally your chosen web server machine has extremely strong encryption of its own, for example requiring manual, on site, 2 factor decryption via a Yubikey e.g. https://github.com/cornelinux/yubikey-luks

- Ideally your chosen web server machine has regular backups for which restoration is also verified on a regular basis.

## How this functions differently from the original:

### Updated luksunlockhttps

In order for the keys to be stored in an encrypted format the ``luksunlockhttps`` script has additional logic to decrypt the keys after download. This also means the hook scripts have additional binaries being made available during boot up (``chmod`` and ``openssl``).

And example of one of these scripts can be seen here: [bin/luksunlockhttps-example](bin/luksunlockhttps-example).

### Updated initramfs hook scripts

These additional hook scripts can be seen in [etc/initramfs-tools/hooks](etc/initramfs-tools/hooks).

I also removed the following section from the curl hook as I require local DNS resolution to poll a LAN based web server:

```bash
# fix DNS resolver (needed for Debian 11 + 12)
echo "nameserver 1.1.1.1\n" > ${DESTDIR}/etc/resolv.conf
```

### Updated dependencies

There are some additional dependencies which are automatically installed, which can be seen in [bin/install-dependencies.sh](bin/install-dependencies.sh).



## How to install:

tl;dr clone, amend and run the installer. Then follow steps shown by the script.

Ensure you amend the webserver URL at the top of ``bin/install.sh`` so ``luksunlockhttps`` scripts are created correctly.

The installer script will automatically install the pre-reqs via invoking the ``bin/install-dependencies.sh`` script.


    # How to conduct a manual, user prompting installation

    cd /tmp
    git clone https://github.com/Aterfax/luks-with-https-unlock.git
    cd luks-with-https-unlock/
    bin/install.sh

    # How to conduct an automated installation:
    #
    # If you know the device you need to target, e.g. "/dev/sda3" you can elect to fully 
    # automate the installation via supplying the device as an argument and an existing
    # LUKS passphrase as a shell environment variable 'LUKSPASSWORD'
    #
    # Note that exporting is mandatory to make this available to subshells invoked in the install script.
    #
    # You should also invoke this script as the root user or you will lack the required permissions.
    #
    # Note: you should reboot promptly or "unset LUKSPASSWORD" after installation completes to decrease the risk of password leakage.

    cd /tmp
    git clone https://github.com/Aterfax/luks-with-https-unlock.git
    cd luks-with-https-unlock/
    read -sp "Enter the LUKS password: " LUKSPASSWORD && export LUKSPASSWORD
    bin/install.sh "/dev/sda3" 

You can then copy your keys to your chosen endpoint, for example with rsync:

    rsync /tmp/lukskeys/*.lek.enc youruser@mybastionhost.domain.com:/var/www/html/

Note: The keys are expected to be provided at the root of the URL, e.g. ``https://mybastionhost.domain.com/31e0d908-70a5-11ef-ad2e-76ac3383469b.lek.enc``

## Optional: Check for your LUKS device and that it has keyslots available

Though I have never personally ran out of slots -

Find your LUKS encrypted device:

    sudo lsblk -l --fs | grep crypto

For example:

    sda3         crypto_LUKS 2              eb571eb0-cff6-11ee-b5c9-fbde751daed9

Check that you have a free slot:

    sudo cryptsetup luksDump /dev/sda3
    

Output should contain output like:

```bash
LUKS header information
Version:        2
Epoch:          4
Metadata area:  16384 [bytes]
Keyslots area:  16744448 [bytes]
UUID:           1d4e0d59-fa9a-445e-8670-ef87e5fa5ff0
Label:          (no label)
Subsystem:      (no subsystem)
Flags:          (no flags)

Data segments:
  0: crypt
        offset: 16777216 [bytes]
        length: (whole device)
        cipher: aes-xts-plain64
        sector: 512 [bytes]

Keyslots:
  0: luks2
        Key:        512 bits
        Priority:   normal
        Cipher:     aes-xts-plain64
        Cipher key: 512 bits
        PBKDF:      argon2id
        Time cost:  4
        Memory:     414784
        Threads:    4
        Salt:       50 34 f7 18 c7 37 2a 59 ca 31 d4 e7 fa 08 e7 e6 
                    70 b7 27 a5 8d bc 85 cc e8 b4 32 0b 93 e9 75 6b 
        AF stripes: 4000
        AF hash:    sha256
        Area offset:32768 [bytes]
        Area length:258048 [bytes]
        Digest ID:  0
Tokens:
Digests:
  0: pbkdf2
        Hash:       sha256
        Iterations: 40156
        Salt:       ce 93 fe 05 d3 0f 58 cc cd 83 a2 45 84 18 2a 48 
                    2a 20 56 d6 f0 2e fc 02 75 94 27 38 12 4b 3a bd 
        Digest:     a8 d3 8a 3a 5c 98 7e 5e 42 9c 14 82 d7 92 4e 4c 
                    0b 8a 93 bd 55 f1 3f 02 80 77 cf f2 35 66 6d 57
```

## Warning and disclaimer

Directly pilfered from the original blog post:

>The above commands modify the initramfs and errors could result in a system that does not boot. Although the commands do not delete your data it may be time consuming to restore access using a rescue image. If you have never updated initramfs from a chroot when booted from a rescue image then I suggested you try that first. And... make sure that you have backups of all your data.
