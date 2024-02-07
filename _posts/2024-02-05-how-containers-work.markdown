---
layout: post
title: "Troubleshooting containers"
subtitle: "understanding containers inside out"
description: "Containers, processes, namespaces, security, troubleshooting"
date: 2024-02-05 00:00:00
background_color: '#1c90ed'
---


# Understanding containerization and improve debugging

As I delve more into kubernetes, the more I get distracted by side quests. This is one of those. In this `DLC`,
I try to understand `containerization`, how it works, and essentially learn how to debug a running docker container.

I had first encountered `chroot` while installing [ArchLinux](https://wiki.archlinux.org/title/installation_guide#Chroot). Basically while installation,
the `/mnt` directory is mounted on your chosen partition, and then after you change root, you are able to access already installed user-space utilities
to setup basic networking, timezones, etc. Maybe install some software.
But there is more to that, the general idea around isolation and how linux kernel works.


Building a container for a process like docker requires taking care of a couple of things:

- `Namespace Isolation`: Utilizes various namespaces (network, PID, UTS, etc.) to isolate the child process from the host's resources.
- `Resource Control`: Sets cgroups limitations for memory, CPU, and other resources for the container.
- `User Mapping`: Optionally uses a user namespace to provide a different UID/GID environment within the container.
- `Seccomp Filtering`: Restricts system calls allowed within the container for enhanced security.
- `Root Filesystem Mounting`: Mounts the specified directory as the container's root filesystem.
- `Capability`: Drops unnecessary capabilities from the container process.


[Linux containers in 500 lines of C](https://blog.lizzie.io/linux-containers-in-500-loc/contained.c)


### Linux filesystem
The Linux, rather The Unix philosophy says `On a UNIX system, everything is a file; if something is not a file, it is a process.`.

So, during the bootup process, the boot loader, loads the selected kernel and the small filesystem (files and folders) called `initrd`.
This contains some userspace code, which is responsible for mounting the `Linux File System`, set it as root, and then runs the boot sequence and 
executing `SysV` initialization system.

Nowadays we have `initramfs`, which is a compressed file. You can read more about this at the kernel docs:

- https://docs.kernel.org/admin-guide/initrd.html
- https://wiki.gentoo.org/wiki/Initramfs_-_make_your_own
- https://man7.org/linux/man-pages/man7/bootup.7.html


**Linux File System**

Its a hierarchical file/folder structure, with a `/` root directory, followed by `/mnt`, `/net`, `/cpu`, `/proc`, `/sys`, etc.
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

```shell
sh1#/ ps -ef
PID   USER     TIME  COMMAND
sh1#/ 
```

You can now mount the host OS's proc into `/proc` of the chrooted directory. And check the processes running on the host os.

```shell
sh1#/ mount -t proc proc /proc
```

Now if we have a process running in host, we can `pkill $HOST_PROCESS_ID` from the child. Overall, **chroot doesn't give you access protection**.


Since both the host and chrooted file systems are under the same namespace, its able to show all the processes from the parent namespace. So we need some form of isolation.
This isolation comes in the process of `namespaces` and `cgroups`. 


**Cgroups** help with limiting how much resources a bunch of applications in the same group can use.

- Resouce limits (hard and soft)
- CPU pinning
- Freeze and unfreeze cgroups to stop and migrate processes.
- IO, network bandwith,
- Monitoring, etc


 These days systemd probably keeps a track of these, and the cgroups can be found in 
 - `ls /sys/fs/cgroup/system.slice/`
 - `ls /sys/fs/cgroup/user.slice/`


**Namespaces** control what a process can see. Namespaces are like subtrees, so namespaces can be nested. The processes in child namespace, won't be aware of the parent namespace.


_We won't be discussing cgroups here, because they are simple to understand_. **Cgroups** are found inside `/sys/fs/cgroups`, but since most modern day OS has systemd, and in systemd these are called slices.

Here is a reference to how you can use cgroups to control the amount of resources used by a program: [cgroups example](https://itnext.io/chroot-cgroups-and-namespaces-an-overview-37124d995e3d). Imma more interested in namespaces.


## Prior knowledge

We need to understand `users` and `capabilities`.

The primary way Linux handles file permissions is through the implementation of `users`. There are normal users, for which Linux applies privilege checking, and there is the superuser that bypasses most (if not all) checks.

Linux `capabilities` were created to provide a more granular application of the security model. Instead of running the binary as root, you can apply only the specific capabilities an application requires to be effective.

**User namespaces** isolate security-related identifiers and attributes, in particular, user IDs and group IDs, keys, root directory and capabilities.

Consider a namespace called `constrained`.The namespace `constrained` will only inherit the permissions/capabilities of the creating process.

If the creating process didn't have full capabilites enabled, the `constrained` namespace wouldn't either.


`Linux containers` uses capabilities to determine what processes can run inside a namespace. For example, lets take the executable `ping`.

```console
sh1#/ which ping
sh1# /usr/bin/ping
sh1#/ cp /usr/bin/ping myping
sh1#/ myping 8.8.8.8
sh1#/
sh1#/
sh1# ./myping: socktype: SOCK_RAW
sh1# ./myping: socket: Operation not permitted
sh1# ./myping: => missing cap_net_raw+p capability or setuid?
sh1#/
sh1#/
sh1#/ # ping needs root privielges to open network socket
sh1#/ sudo chown root myping
sh1#/ sudo myping 8.8.8.8
sh1#/
sh1#/ # but we want to invoke it without sudo. we set the setuid bit. with +s
h1#/
sh1# sudo chmod +s myping
sh1#/
sh1#/ myping 8.8.8.8
sh1# PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
sh1# 64 bytes from 8.8.8.8: icmp_seq=1 ttl=63 time=45.7 ms
```

So preventing this by carefully crafting capabilities become important.


## Namespaces

A [namespace](https://www.man7.org/linux/man-pages/man7/namespaces.7.html) wraps a global system resource in an abstraction that makes it appear to the processes 
within the namespace that they have their own isolated instanceof the global resource.

There are a few [different kinds of namespaces](https://www.redhat.com/sysadmin/7-linux-namespaces) and further maybe added.

- cgroup_namespaces
- pid_namespaces
- network_namespaces
- mnt_namespaces
- uts_namespaces
- user_namespaces


**Tools needed to improve understanding**:

- `lsns`, to list namespaces
- `unshare`, to create namespace and move the calling process to the new namespace.
- `nsenter`, executes program in the namespace(s), specified as args.
- `clone`, to create new processes in a new namespace from parent process.
- `setns`, move the calling process to another existing namespace.


`Linux containers` or `docker` employs a bunch of these namespacing and cgroups to run processes which runs the program in isolation. It also sorts out network topology, using veth and switches. Understanding them will also help
us debug containers from outside, by mounting containers with debug tools in the same namespaces.


### user_namespaces

As described above user namespace is a collection of capabilities, user ids etc. In addition they can be nested.

There can be multiple nestations. The parent namespace will see the child namespaces having the same `user ID`.And hence have access to all the files.


However the child namespaces cannot interract with the parent namespaces. Because to the child namepsace, the child namespaces perceives itself as PID: 1. So its world starts from itself.


### mount_namespaces

This are a bit complicated. Mount namespaces provide isolation of the list of mounts seen by the processes in each namespace instance.
Thus, the processes in each of the mount namespace instances will see distinct single-directory hierarchies. 

This lets us mount and unmount filesystems, without affecting the whole system. So in case of `docker`,
each container can have its own root file system, in isolation, and also not affect any other containers or host filesystem.

Mount namespace can also be nested, but the visibility of the mounted or unmounted filesystem depends on the `propagation_type` configuration.


This configuration is provided during the `mount` phase.

The [docs](https://www.man7.org/linux/man-pages/man7/mount_namespaces.7.html) provide examples into how mount and visibility works. But here are the key details.


Depending on the propagation_type type for each mount, the mount and unmount events are propagated to peers. Why do we need peers? In order to be able to automatically mount filesystems into all mount namespaces (depedning
on scenario), linux needed something called `shared subtrees`.

Once mounted, these devices are marked with a `mount state`. like `shared:*`, `master:*`, '<Nothing>'.
- Shared meanining all the processes in the namespace can see the mounted or unmounted device.
- Private is not shared, so no peering
- Master/slave is where events propagate to the namespace from shared ones, but they do send events to their peers.

When creating a less privileged mount namespace, shared mounts are reduced to slave mounts. This ensures that mappings performed in less privileged mount namespaces will 
not propagate to more privileged mount namespaces.

```console
PS1='sh1#'

sh1#/ mount --make-shared /mntX
sh1#/ mount --make-private /mntY

#/ cat /proc/self/mountinfo | grep '/mnt' | sed 's/ - .*//'

77 61 8:17 / /mntX rw,relatime shared:1
83 61 8:15 / /mntY rw,relatime
```

We can see, `/mntX` has `shared:1`, while `/mntY` is private. Creating nampespace and mounting in sub directories should make them inherit this `mount state`

```console
#/ PS1='sh2# ' sudo unshare -m --propagation unchanged sh
sh2#/ mkdir /mntX/a && mount /dev/sdb6 /mntX/a
sh2#/ mkdir /mntY/b && mount /dev/sdb7 /mntY/b

sh2#/ cat /proc/self/mountinfo

222 145 8:17 / /mntX rw,relatime shared:1
225 145 8:15 / /mntY rw,relatime
178 222 8:22 / /mntX/a rw,relatime shared:2
230 225 8:23 / /mntY/b rw,relatime
```

from the parent namespace `sh1#/ cat /proc/self/mountinfo`, we can't see the `/mntY/b`, because of the mount state and propagaition type set to `private`:

```
77 61  8:17 / /mntX rw,relatime shared:1
83 61  8:15 / /mntY rw,relatime
179 77 8:22 / /mntX/a rw,relatime shared:2
```


Let's check a case where privileges are downgraded.

```shell
sh1#/ mount --make-shared /mntZ
sh1#/ cat /proc/self/mountinfo

133 83 8:22 / /mntZ rw,relatime shared:1

sh1#/ PS1='sh2#' sudo unshare -m --propagation unchanged sh
```

```shell
sh2#/ mount --make-slave /mntY
sh2#/ cat /proc/self/mountinfo

169 167 8:22 / /mntZ rw,relatime master:1
```

```shell
sh2#/ mkdir /mntZ/c && mount /dev/sda8 /mntZ/c
sh2#/ cat /proc/self/mountinfo

169 167 8:22 / /mntZ rw,relatime master:1
175 169 8:5 / /mntZ/c rw,relatime
```

we can see, the `/mntZ/c` has dropped priveleges. But this is opaque to the parent namespace.

```shell
sh1#/ cat /proc/self/mountinfo

133 83 8:22 / /mntZ rw,relatime shared:1
```

So, if we create a mount point for `/mntZ/d` from this namespace it should be visible, because of `shared`. But inside the namespace `sh2`, it gets degraded to `slave/master`

```shell
sh1#/ mkdir -p /mntZ/d && mount /dev/sdb9 /mntZ/d
sh1#/ cat /proc/self/mountinfo

178 133 8:1 / /mntZ/d rw,relatime shared:2

sh2#/ cat /proc/self/mountinfo

179 169 8:1 / /mntZ/d rw,relatime master:2
```


### uts_namespaces

This is mostly used to isolate the hostname. So lets create a uts namespace in the `rootfs` alipne image.


### pid_namespaces

When a process is created on most Unix-like operating systems, it is given a specific numeric identifier called a `process ID(PID)`.
All of these processes are tracked in a special file system called `procfs`. and is mounted under `/proc`.

PID namespaces isolate the `process ID number space`, meaning that processes in different PID namespaces can have the same PID.  PID
namespaces allow containers to provide functionality such as suspending/resuming the set of processes in the container and migrating 
the container to a new host while the processes inside the container maintain the same PIDs.


A `/proc` virtual filesystem shows (in the /proc/pid directories) only processes visible in the PID namespace of the process that 
performed the mount, even if the `/proc` filesystem is viewed from processes in other namespaces. As shown before.

> A caveat of the creating the pid_namespace is, the process that initiates the creation of a new PID namespace with `unshare` does not enter the new namespace; only its child processes do.
In our system
- for kernel the PID is 0
- PID = 1 is the assigned to init, which is the first process in the `user space`.

There are some special stuff that goes on while handling `PID = 1`. You can find them [here](https://medium.com/hackernoon/the-curious-case-of-pid-namespaces-1ce86b6bc900):


First lets check the contents of `/`

```console
vagrant@vagrant:~/containerization$ ls /

bin  boot  dev  etc  home  lib  lib32  lib64  libx32  lost+found  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  vagrant  var
```

In here, we definetly don't need to the `lost+found`, so we will need to clean them after. Because the child namespaces will inherit the mount points from the parent processes. Reducing image size by removing unnecessary files.
Also disallowing access to modifications in the parent namespace.


```shell
vagrant@vagrant:~/containerization$ unshare -Urfpm --mount-proc
vagrant@vagrant:~/containerization$ mkdir -p rootfs/.oldroot

root@vagrant:~/containerization# ls /
bin  boot  dev  etc  home  lib  lib32  lib64  libx32  lost+found  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  vagrant  var


root@vagrant:~/containerization# mount
/dev/sda1 on / type ext4 (rw,relatime,discard,errors=remount-ro)
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot)
pstore on /sys/fs/pstore type pstore (rw,nosuid,nodev,noexec,relatime)
bpf on /sys/fs/bpf type bpf (rw,nosuid,nodev,noexec,relatime,mode=700)
debugfs on /sys/kernel/debug type debugfs (rw,nosuid,nodev,noexec,relatime)
tracefs on /sys/kernel/tracing type tracefs (rw,nosuid,nodev,noexec,relatime)
fusectl on /sys/fs/fuse/connections type fusectl (rw,nosuid,nodev,noexec,relatime)
configfs on /sys/kernel/config type configfs (rw,nosuid,nodev,noexec,relatime)
... etc

# we need to bind the rootfs folder to a folder in the new namespace
root@vagrant:~/containerization# mount --rbind rootfs rootfs
root@vagrant:~/containerization# mount

/dev/sda1 on / type ext4 (rw,relatime,discard,errors=remount-ro)
proc on /proc type proc (rw,nosuid,nodev,noexec,relatime)
/dev/sda1 on /home/vagrant/containerization/rootfs type ext4 (rw,relatime,discard,errors=remount-ro)
none on /home/vagrant/containerization/rootfs/proc type proc (rw,relatime)

root@vagrant:~/containerization# PATH=/bin:/sbin:$PATH # because apline's PATH doesn't have sbin
root@vagrant:~/containerization# mount

/dev/sda1 on /.oldroot2 type ext4 (rw,relatime,discard,errors=remount-ro)
none on /.oldroot2/home/vagrant/containerization/rootfs/proc type proc (rw,relatime)
proc on /.oldroot2/proc type proc (rw,nosuid,nodev,noexec,relatime)
/dev/sda1 on / type ext4 (rw,relatime,discard,errors=remount-ro)
none on /proc type proc (rw,relatime)

# we could mount the proc and tmpfs file system.


root@vagrant:~/containerization# umount -l /.oldroot2
root@vagrant:~/containerization# mount

/dev/sda1 on / type ext4 (rw,relatime,discard,errors=remount-ro)
none on /proc type proc (rw,relatime)
proc on /proc type proc (rw,relatime)
root@vagrant:~/containerization#


root@vagrant:~/containerization# echo 'lopard' > /tmp/sometext
root@vagrant:~/containerization# cat /tmp/sometext
lopard

root@vagrant:~/containerization# exit
logout

vagrant@vagrant:~/containerization$ cat /tmp/sometext
cat: /tmp/sometext: No such file or directory
```

**How to use this knowledge to interract with docker containers**

In order to see this, lets start a `docker container` with a `nginx` server running. And inspect the directories from there.

```console
root@vagrant:~# docker run --name webserver -d nginx
root@vagrant:~# sudo lsns

        NS TYPE   NPROCS   PID USER    COMMAND
4026532167 mnt         3  5426 root    nginx: master process nginx -g daemon off;
4026532168 uts         3  5426 root    nginx: master process nginx -g daemon off;
4026532169 ipc         3  5426 root    nginx: master process nginx -g daemon off;
4026532170 pid         3  5426 root    nginx: master process nginx -g daemon off;
4026532171 net         3  5426 root    nginx: master process nginx -g daemon off;
4026532242 cgroup      3  5426 root    nginx: master process nginx -g daemon off;

# we can see the process id is 5426, we can also check it using
root@vagrant:~# docker inspect -f '{{.State.Pid}}' webserver
root@vagrant:~# 
root@vagrant:~# findmnt -N 5426
TARGET                  SOURCE               FSTYPE  OPTIONS
/                       overlay              overlay rw,relatime,lowerdir=/var/lib/docker/overlay2/l/IZIA76DUQYFLCEM6U6T4JUAXKU:/var/lib/docker/overlay2/l/EAJ2MHCQ4VHZ24ER57333HY2ZO:/var/lib/docker/overlay2/l/T5SEXCKKH5MODEFH44MWNERUFN:/var/lib/do
├─/proc                 proc                 proc    rw,nosuid,nodev,noexec,relatime
│ ├─/proc/bus           proc[/bus]           proc    ro,nosuid,nodev,noexec,relatime
│ ├─/proc/fs            proc[/fs]            proc    ro,nosuid,nodev,noexec,relatime
│ ├─/proc/irq           proc[/irq]           proc    ro,nosuid,nodev,noexec,relatime
│ ├─/proc/sys           proc[/sys]           proc    ro,nosuid,nodev,noexec,relatime
│ ├─/proc/sysrq-trigger proc[/sysrq-trigger] proc    ro,nosuid,nodev,noexec,relatime
│ ├─/proc/acpi          tmpfs                tmpfs   ro,relatime,inode64
│ ├─/proc/kcore         tmpfs[/null]         tmpfs   rw,nosuid,size=65536k,mode=755,inode64
│ ├─/proc/keys          tmpfs[/null]         tmpfs   rw,nosuid,size=65536k,mode=755,inode64
│ └─/proc/timer_list    tmpfs[/null]         tmpfs   rw,nosuid,size=65536k,mode=755,inode64
├─/dev                  tmpfs                tmpfs   rw,nosuid,size=65536k,mode=755,inode64
│ ├─/dev/pts            devpts               devpts  rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=666
│ ├─/dev/mqueue         mqueue               mqueue  rw,nosuid,nodev,noexec,relatime
│ └─/dev/shm            shm                  tmpfs   rw,nosuid,nodev,noexec,relatime,size=65536k,inode64
├─/sys                  sysfs                sysfs   ro,nosuid,nodev,noexec,relatime
│ ├─/sys/firmware       tmpfs                tmpfs   ro,relatime,inode64
│ └─/sys/fs/cgroup      cgroup[/system.slice/docker-b509c5f9e86e1b9241ab80a44be1f990148c523c5233cf5d69453ec3ea459d6e.scope]
│                                            cgroup2 ro,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot
├─/etc/resolv.conf      /dev/sda1[/var/lib/docker/containers/b509c5f9e86e1b9241ab80a44be1f990148c523c5233cf5d69453ec3ea459d6e/resolv.conf]
│                                            ext4    rw,relatime,discard,errors=remount-ro
├─/etc/hostname         /dev/sda1[/var/lib/docker/containers/b509c5f9e86e1b9241ab80a44be1f990148c523c5233cf5d69453ec3ea459d6e/hostname]
│                                            ext4    rw,relatime,discard,errors=remount-ro
└─/etc/hosts            /dev/sda1[/var/lib/docker/containers/b509c5f9e86e1b9241ab80a44be1f990148c523c5233cf5d69453ec3ea459d6e/hosts]
                                             ext4    rw,relatime,discard,errors=remount-ro

# we can see the mount list for the container
root@vagrant:~# 
root@vagrant:~# nsenter --target 5426 --mount ls /
bin  boot  dev  docker-entrypoint.d  docker-entrypoint.sh  etc  home  lib  lib32  lib64  libx32  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var

root@vagrant:~# docker exec webserver touch new_test_file
root@vagrant:~#
root@vagrant:~# ls /proc/5426/root | grep new_test
new_test_file
```
The last bit shows, that, `linux containers` are basically `processes` that can be interracted with using regular `linux system tools`. 


**Troubleshoot**

We might need to check on our processes inside out container. We can mount the `mnt/` and `pid namespace`.

```shell

root@vagrant:~# nsenter --target 5426 -m -p ps -ef
nsenter: failed to execute ps: No such file or directory

root@vagrant:~# nsenter --target 5426 -m -p apt-get install procps
root@vagrant:~# nsenter --target 5426 -m -p ps -ef

UID          PID    PPID  C STIME TTY          TIME CMD
root           1       0  0 17:37 ?        00:00:00 nginx: master process nginx -g daemon off;
nginx         29       1  0 17:37 ?        00:00:00 nginx: worker process

root@vagrant:~# docker run -it --name debug-server-2 --pid=container:webserver --network=container:webserver raesene/alpine-containertools /bin/bash
bash-5.1#
bash-5.1#
bash-5.1# ps -f
PID   USER     TIME  COMMAND
    1 root      0:00 nginx: master process nginx -g daemon off;
   29 101       0:00 nginx: worker process
   30 101       0:00 nginx: worker process
  258 root      0:00 /bin/bash
  264 root      0:00 ps -f
```

This works because we are creating a new namespace (debug-server-2), with the pid_namespace of the `webserver` container.


### network namespaces

This is used to manage the network stack between namespaces, routing tables, IP addresses, sockets etc. We basically need to be aware of two things:
- veth, configure a point-to-point net namespace, between two namespaces. (server and db namespace)
- switch, connecting multiple namespaces.

[Redhat](https://www.redhat.com/sysadmin/net-namespaces), has a great article on how to set up `virtual ethernet` between two namespaces, and assigning ips to them.
We are going to see this in context of `docker`.

Lets try to find the `ip` of the `nginx box`

```shell
root@vagrant:~# docker exec webserver ip addr
OCI runtime exec failed: exec failed: unable to start container process: exec: "ip": executable file not found in $PATH: unknown

# nsenter with the network namespace loaded

root@vagrant:~# nsenter --target 5426 --net ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
6: eth0@if7: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
root@vagrant:~#
```

**Troubleshoot**

We can leverage joining processes from a new container to the network namespace from another (webserver) container. In linux terms it probably looks like

```shell
WEB_SERVER_PID=$(docker inspect -f '{{.State.Pid}}' webserver)

# Join the network namespace
unshare --net=/proc/$WEB_SERVER_PID/ns/net /bin/bash
```

Coming back to debugging with another docker container. 

```shell
bash-5.1# netstat -tunap
Active Internet connections (servers and established)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      -
tcp        0      0 :::80                   :::*                    LISTEN      -
bash-5.1# ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
6: eth0@if7: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever

```


## Other details:

**Apparmor**  

Apparmor is a mandatory ACL system that confines programs according to a set of rules that specify what files a given program can access. This proactive approach helps protect the system against both known and unknown vulnerabilities.
Even for root users.

This provides additional layer of security, apart from cgroups and namespaces and capabilites (`CAP_*`)

**seccomp**

This is used to allow or block specific `syscalls` for a `container/process`. These are enforced by guys at [docker](https://docs.docker.com/get-started/). For example, `unshare` is not permitted inside a docker container.
This can be turned of using `--security-opt seccomp=unconfined`.


Both of these are ways to allow isolation in the container. I think we have enough knowledge about how to work with `processes`, `namespaces`, `mounts`. We haven't covered `network` in depth, but the article on Redhat,
alreay has a great explanation. Also there are different kinds of networks that docker allows, and it needs a separate post.


## Notes


### PID = 1 

Inside a namespace, init (pid 1) has three unique features when compared to other processes:

- It does not automatically get default signal handers, so a signal sent to it is ignored unless it registers a signal hander for that signal.
(This is why many dockerized processes fail to respond to ctrl-c and you are forced to kill them with something like `docker kill`).
- If another process in the namespace dies before its children, its children will be `re-parented` to `pid 1`. This allows `init` to collect the exit status of the child processes so that the kernel can remove it from the process table.
- If it dies, every other process in the pid namespace will be forcibly terminated and the namespace will be cleaned up.


This prevents us from doing `unshare --pid --mount-proc /bin/bash`. This will cause an error: `Error: bash: fork: Cannot allocate memory`, because,
`unshare` will exectue `/bin/bash`, which will load some `shell modules`. 

The first process in that becomes `PID = 1`. When the process `exit`s, it causes `re-paranting`, and then `terminating all other processes in namespace`.

This eventually causes `init` of the host process, and the state change, and `creation of process` fails because PID cannot be allocated, resulting in the error, `Cannot allocate memory`



## References:

- [https://www.redhat.com/sysadmin/building-container-namespaces](https://www.redhat.com/sysadmin/building-container-namespaces)
- [https://www.man7.org/linux/man-pages/man7/namespaces.7.html](https://www.man7.org/linux/man-pages/man7/namespaces.7.html)
- [https://www.man7.org/linux/man-pages/man7/mount_namespaces.7.html](https://www.man7.org/linux/man-pages/man7/mount_namespaces.7.html)
- [https://www.man7.org/linux/man-pages/man7/user_namespaces.7.html](https://www.man7.org/linux/man-pages/man7/user_namespaces.7.html)
- [https://www.man7.org/linux/man-pages/man7/pid_namespaces.7.html](https://www.man7.org/linux/man-pages/man7/pid_namespaces.7.html)
- [https://www.redhat.com/sysadmin/net-namespaces](https://www.redhat.com/sysadmin/net-namespaces)
- [https://akashrajpurohit.com/blog/build-your-own-docker-with-linux-namespaces-cgroups-and-chroot-handson-guide/](https://akashrajpurohit.com/blog/build-your-own-docker-with-linux-namespaces-cgroups-and-chroot-handson-guide/)
- [https://www.alanjohn.dev/blog/Deep-dive-into-Containerization-Creating-containers-from-scratch](https://www.alanjohn.dev/blog/Deep-dive-into-Containerization-Creating-containers-from-scratch)
- [https://www.youtube.com/watch?v=0kJPa-1FuoI](https://www.youtube.com/watch?v=0kJPa-1FuoI)
- [https://www.youtube.com/watch?list=RDCMUCPO2QgTCReBAThZca6MB9jg](https://www.youtube.com/watch?v=EFOA2nCZ0gg&list=RDCMUCPO2QgTCReBAThZca6MB9jg&start_radio=1&rv=EFOA2nCZ0)


`Thank you.`
