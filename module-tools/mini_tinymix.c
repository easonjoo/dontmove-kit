/* mini_tinymix.c — 极简 ALSA mixer 工具（静态编译，供 QDC507 模块使用）
 * 用法:
 *   mini_tinymix list                 列出全部控件
 *   mini_tinymix get <name>           读取控件值
 *   mini_tinymix set <name> <value>   写控件值（enum 传索引，bool 传 0/1）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <stdint.h>
#include <sound/asound.h>

static int ctl_fd;

static int elem_info(struct snd_ctl_elem_info *info) {
    return ioctl(ctl_fd, SNDRV_CTL_IOCTL_ELEM_INFO, info);
}

static void dump_value(struct snd_ctl_elem_info *info, struct snd_ctl_elem_value *val) {
    unsigned int i;
    switch (info->type) {
    case SNDRV_CTL_ELEM_TYPE_BOOLEAN:
    case SNDRV_CTL_ELEM_TYPE_INTEGER:
        for (i = 0; i < info->count; i++)
            printf("%s%ld", i ? "," : "", val->value.integer.value[i]);
        break;
    case SNDRV_CTL_ELEM_TYPE_ENUMERATED:
        for (i = 0; i < info->count; i++) {
            struct snd_ctl_elem_info tmp = *info;
            long idx = val->value.enumerated.item[i];
            tmp.value.enumerated.item = (unsigned int)idx;
            if (ioctl(ctl_fd, SNDRV_CTL_IOCTL_ELEM_INFO, &tmp) == 0)
                printf("%s%ld=%s", i ? "," : "", idx, tmp.value.enumerated.name);
            else
                printf("%s%ld", i ? "," : "", idx);
        }
        break;
    case SNDRV_CTL_ELEM_TYPE_INTEGER64:
        for (i = 0; i < info->count; i++)
            printf("%s%lld", i ? "," : "", (long long)val->value.integer64.value[i]);
        break;
    default:
        printf("(type=%d)", info->type);
    }
    printf("\n");
}

static int cmd_list(void) {
    struct snd_ctl_elem_list list;
    memset(&list, 0, sizeof(list));
    if (ioctl(ctl_fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
        perror("ELEM_LIST"); return 1;
    }
    unsigned int count = list.count;
    struct snd_ctl_elem_id *ids = calloc(count, sizeof(*ids));
    if (!ids) return 1;
    memset(&list, 0, sizeof(list));
    list.space = count;
    list.pids = ids;
    if (ioctl(ctl_fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list) < 0) {
        perror("ELEM_LIST"); return 1;
    }
    for (unsigned int i = 0; i < count; i++) {
        struct snd_ctl_elem_info info;
        memset(&info, 0, sizeof(info));
        info.id = ids[i];
        if (elem_info(&info) < 0) continue;
        printf("%3u: iface=%d name='%s' type=%d count=%u\n",
               i, info.id.iface, info.id.name, info.type, info.count);
    }
    free(ids);
    return 0;
}

static int find_by_name(const char *name, struct snd_ctl_elem_info *info) {
    memset(info, 0, sizeof(*info));
    info->id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
    strncpy((char *)info->id.name, name, sizeof(info->id.name) - 1);
    if (elem_info(info) < 0) {
        fprintf(stderr, "控件不存在: %s (%s)\n", name, strerror(errno));
        return -1;
    }
    return 0;
}

static int cmd_get(const char *name) {
    struct snd_ctl_elem_info info;
    struct snd_ctl_elem_value val;
    if (find_by_name(name, &info) < 0) return 1;
    memset(&val, 0, sizeof(val));
    val.id = info.id;
    if (ioctl(ctl_fd, SNDRV_CTL_IOCTL_ELEM_READ, &val) < 0) {
        perror("ELEM_READ"); return 1;
    }
    dump_value(&info, &val);
    return 0;
}

static int cmd_set(const char *name, const char *value) {
    struct snd_ctl_elem_info info;
    struct snd_ctl_elem_value val;
    if (find_by_name(name, &info) < 0) return 1;
    memset(&val, 0, sizeof(val));
    val.id = info.id;
    long v = strtol(value, NULL, 0);
    for (unsigned int i = 0; i < info.count; i++) {
        switch (info.type) {
        case SNDRV_CTL_ELEM_TYPE_ENUMERATED:
            val.value.enumerated.item[i] = v; break;
        case SNDRV_CTL_ELEM_TYPE_INTEGER64:
            val.value.integer64.value[i] = v; break;
        default:
            val.value.integer.value[i] = v; break;
        }
    }
    if (ioctl(ctl_fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &val) < 0) {
        fprintf(stderr, "写入失败 %s=%s: %s\n", name, value, strerror(errno));
        return 1;
    }
    memset(&val, 0, sizeof(val));
    val.id = info.id;
    ioctl(ctl_fd, SNDRV_CTL_IOCTL_ELEM_READ, &val);
    printf("%s => ", name);
    dump_value(&info, &val);
    return 0;
}

int main(int argc, char **argv) {
    ctl_fd = open("/dev/snd/controlC0", O_RDWR);
    if (ctl_fd < 0) { perror("open controlC0"); return 1; }
    int rc = 1;
    if (argc >= 2 && !strcmp(argv[1], "list")) rc = cmd_list();
    else if (argc >= 3 && !strcmp(argv[1], "get")) rc = cmd_get(argv[2]);
    else if (argc >= 4 && !strcmp(argv[1], "set")) rc = cmd_set(argv[2], argv[3]);
    else fprintf(stderr, "用法: %s list | get <name> | set <name> <value>\n", argv[0]);
    close(ctl_fd);
    return rc;
}
