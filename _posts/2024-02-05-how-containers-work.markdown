---
layout: post
title: "Building an ecommerce website end to end"
subtitle: "career breaks doesn't mean end of work"
description: "Going for a productive career break"
date: 2024-01-11 00:00:00
background_color: '#1c90ed'
---


## Understanding containerization and improve debugging

As I delve more into kubernetes, the more I get distracted by side quests. This is one of those. In this `DLC`,
I try to understand `containerization`, how it works, and essentially learn how to debug a running docker container.

I had first encountered `chroot` while installing [ArchLinux](https://wiki.archlinux.org/title/installation_guide#Chroot). Basically while installation,
the `/mnt` directory is mounted on your chosen partition, and then after you change root, you are able to access already installed user-space utilities
to setup basic networking, timezones, etc. Maybe install some software.

But there is more to that, the general idea around isolation and how linux kernel works.


### Linux filesystem

The Linux, rather The Unix philosophy says `On a UNIX system, everything is a file; if something is not a file, it is a process.`.

So, during the bootup process, the boot loader, loads the selected kernel and the small filesystem (files and folders) called `initrd`.
This contains some userspace code, which is responsible for mounting the `Linux File System`, set it as root, and then runs the boot sequence and 
executing `SysV` initialization system.

Nowadays we have `initramfs`, which is a compressed file.

You can read more about this at the kernel docs:
- https://docs.kernel.org/admin-guide/initrd.html
- https://wiki.gentoo.org/wiki/Initramfs_-_make_your_own
- https://man7.org/linux/man-pages/man7/bootup.7.html


**Linux File System**

Its a hierarchical file/folder structure, with a `/` root directory, followed by `/mnt', `/net`, `/cpu`, `/proc`, `/sys`, etc.
Some are real files, some are virtual representations.

We can see that using a docker image, and inspecting the contents. And comparing with our linux system.


```shell
docker run -it --name busyback alpine:latest true
docker container export busybuck | gzip > busybuck.tar.gz
mkdir -p rootfs && tar -xvf busybuck.tar.gz --directory rootfs
```

```shell
> cd rootfs && tree -L 1

├── bin
├── dev
├── etc
├── home
├── lib
├── media
├── mnt
├── opt
├── proc
├── root
├── run
├── sbin
├── srv
├── sys
├── tmp
├── usr
└── var
```

This is also what the output of `ls -l /` looks like. So basically, the container has a similar directory structure, with similar user-space programs.

```shell
sudo chroot rootfs /bin/sh
```

This should drop you to a shell. And you can run `ps -ef` in it.

Things to understand:
- whats a loopback interface and a loop device
- the root filesystem and chroot
- old way using dd and deb-bootstraping with config scripts
- linux namespaces, why they exists, types of namespaces.
- linux tools to create such things.
- docker images a stackof tarballs that represent the rootfs
- security
