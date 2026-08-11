/*
 * tests/linux/ns_probe.c — what the kernel will and will not let this boot do
 * with namespaces. It is the measurement the root switch in
 * user/linux-syscalls.c was designed from, kept so the numbers can be taken
 * again on another kernel rather than believed from a comment.
 *
 * Deliberately a plain C program with no Adder and no runtime: it has to be
 * able to answer questions ABOUT the runtime, and it runs before there is
 * anything to trust. Build it on the host and stage it into the image:
 *
 *     gcc -O0 -o build/image/root/bin/ns_probe tests/linux/ns_probe.c
 *     # repack the initramfs, then from a boot rc:
 *     /bin/ns_probe 0    /n/distro     # as root
 *     /bin/ns_probe 1001 /n/distro     # as the session user
 *
 * It walks the whole sequence an `enter` performs -- drop to the given uid,
 * take a private mount namespace (creating a user namespace if that is the
 * only way to get one), assemble a new root, switch onto it, replay the rest
 * of the namespace template -- and prints what each step answered. The two
 * lines that decided the design, on the live initramfs boot:
 *
 *     nsprobe: initial root mount id=38 parent=38 UNATTACHED | ... rootfs
 *     nsprobe: RESULT pivot_root(".","."): FAIL Invalid argument
 *     nsprobe: RESULT MS_MOVE -> /: OK
 *     nsprobe: RESULT after-switch nested CLONE_NEWUSER: OK
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/prctl.h>

#define P(...) do{ printf("nsprobe: " __VA_ARGS__); fflush(stdout);}while(0)

static void wr(const char*f,const char*s){int fd=open(f,O_WRONLY);
    if(fd<0){P("  open %s: FAIL %s\n",f,strerror(errno));return;}
    if(write(fd,s,strlen(s))<0)P("  write %s <- '%s': FAIL %s\n",f,s,strerror(errno));
    else P("  write %s <- '%s': OK\n",f,s);
    close(fd);}
static void nested(const char*tag){pid_t p=fork();
    if(p==0){int r=unshare(CLONE_NEWUSER);
        P("RESULT %s nested CLONE_NEWUSER: %s\n",tag,r<0?strerror(errno):"OK");
        fflush(stdout);_exit(0);} int st;waitpid(p,&st,0);}
/* is `dst` a mountpoint of fstype `fs` in this ns? */
static int is_mount_of(const char*dst,const char*fs){
    FILE*f=fopen("/proc/self/mountinfo","r");char l[4096];int hit=0;
    while(f&&fgets(l,sizeof l,f)){char mp[512];char*d=strstr(l," - ");
        if(!d)continue;char ty[128];
        if(sscanf(l,"%*d %*d %*s %*s %511s",mp)!=1)continue;
        if(sscanf(d+3,"%127s",ty)!=1)continue;
        if(!strcmp(mp,dst)&&!strcmp(ty,fs))hit=1;}
    if(f)fclose(f);return hit;}

int main(int argc,char**argv){
    int uid=argc>1?atoi(argv[1]):1001;
    const char*src=argc>2?argv[2]:"/n/distro";
    P("=== nsprobe2 uid=%d src=%s\n",uid,src);
    if(uid){ if(setgid(uid)<0)P("setgid: %s\n",strerror(errno));
             if(setuid(uid)<0){P("setuid: FAIL %s\n",strerror(errno));return 1;} }
    P("uid=%d dumpable=%d\n",(int)getuid(),prctl(PR_GET_DUMPABLE));
    if(unshare(CLONE_NEWNS)<0){
        P("unshare(NEWNS): FAIL %s -> escalating\n",strerror(errno));
        uid_t u=getuid();gid_t g=getgid();char b[64];
        P("prctl(SET_DUMPABLE,1): %s\n",prctl(PR_SET_DUMPABLE,1)<0?strerror(errno):"OK");
        if(unshare(CLONE_NEWUSER|CLONE_NEWNS)<0){P("unshare(NEWUSER|NEWNS): FAIL %s\n",strerror(errno));return 1;}
        wr("/proc/self/setgroups","deny");
        snprintf(b,sizeof b,"%u %u 1\n",u,u); wr("/proc/self/uid_map",b);
        snprintf(b,sizeof b,"%u %u 1\n",g,g); wr("/proc/self/gid_map",b);
        P("in userns: uid=%d euid=%d\n",(int)getuid(),(int)geteuid());
    } else P("unshare(NEWNS): OK (privileged)\n");
    P("make-rprivate: %s\n",mount(NULL,"/",NULL,MS_REC|MS_PRIVATE,NULL)<0?strerror(errno):"OK");

    /* what enter_root would do, with the "already mounted -> bind" rule */
    static char stage[256];
    mkdir("/n",0755);
    if(mkdir("/n/.root",0755)==0||errno==EEXIST) strcpy(stage,"/n/.root");
    else { snprintf(stage,sizeof stage,"/tmp/.hamns-%d",(int)getpid());
           if(mkdir(stage,0700)<0&&errno!=EEXIST){P("stage mkdir %s: FAIL %s\n",stage,strerror(errno));return 1;} }
    P("stage dir = %s\n",stage);
    char sd[512];
    P("bind %s -> %s: %s\n",src,stage,
      mount(src,stage,NULL,MS_BIND|MS_REC,NULL)<0?strerror(errno):"OK");
    const char*carry[]={"/dev","/proc","/sys","/n"};
    for(int i=0;i<4;i++){snprintf(sd,sizeof sd,"%s%s",stage,carry[i]);
        int mk=mkdir(sd,0755);
        P("  rbind %s (mkdir %s): %s\n",carry[i],mk==0?"made":(errno==EEXIST?"exists":strerror(errno)),
          mount(carry[i],sd,NULL,MS_BIND|MS_REC,NULL)<0?strerror(errno):"OK");}
    if(chdir(stage)<0){P("chdir: %s\n",strerror(errno));return 1;}
    if(mount(".","/",NULL,MS_MOVE,NULL)<0){P("RESULT MS_MOVE -> /: FAIL %s\n",strerror(errno));return 1;}
    P("RESULT MS_MOVE -> /: OK\n");
    if(chroot(".")<0){P("chroot: FAIL %s\n",strerror(errno));return 1;}
    if(chdir("/")<0)P("chdir /: %s\n",strerror(errno));
    P("RESULT root switched; /etc/debian_version=%d\n",access("/etc/debian_version",F_OK)==0);

    /* the rest of the template */
    struct { const char*dst; const char*fs; } t[] = {
        {"/dev","devtmpfs"},{"/proc","proc"},{"/srv","tmpfs"},
    };
    for(unsigned i=0;i<sizeof t/sizeof t[0];i++){
        mkdir(t[i].dst,0755);
        int r=mount(t[i].fs,t[i].dst,t[i].fs,0,NULL);
        P("mount -t %s %s: %s%s\n",t[i].fs,t[i].dst,r<0?strerror(errno):"OK",
          r<0?(is_mount_of(t[i].dst,t[i].fs)?"  [but ALREADY a mount of that type]":"  [and not present]"):"");
    }
    mkdir("/n",0755);
    P("bind / -> /n: %s\n",mount("/","/n",NULL,MS_BIND|MS_REC,NULL)<0?strerror(errno):"OK");

    nested("after-switch");
    /* can we run a debian binary? */
    pid_t p=fork();
    if(p==0){ execl("/bin/sh","sh","-c","echo nsprobe: BODY id=$(id -u) $( . /etc/os-release; echo $PRETTY_NAME)",(char*)0);
              P("exec /bin/sh: FAIL %s\n",strerror(errno));fflush(stdout);_exit(127);}
    int st;waitpid(p,&st,0);P("body status=%d\n",WEXITSTATUS(st));
    P("=== done\n");return 0;
}
