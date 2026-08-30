/*
 * synotoolbox-helper.c
 *
 * Narrow setuid-root launcher for Syno_Toolbox.
 * Installed by DSM owner root:<package>, mode 6550 (setuid), from conf/privilege.
 *
 * This replaces the sudoers-based escalation: it does not depend on
 * /usr/bin/sudo being present, and only ever executes one fixed,
 * hardcoded script path with a whitelisted, single argument.
 */

#define _GNU_SOURCE
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#ifndef TARGET_SCRIPT
#define TARGET_SCRIPT "/var/packages/Syno_Toolbox/target/bin/synotoolbox_api.sh"
#endif

int main(int argc, char *argv[])
{
    const char *no_arg[]  = { "getstate", "listvolumes", "listshares", "discovernas", "selfheal", "runboot", NULL };
    const char *one_arg[] = { "run", "check", "save", "listfolder", NULL };

    if (argc < 2) {
        fprintf(stderr, "synotoolbox-helper: missing subcommand\n");
        return 1;
    }
    const char *cmd = argv[1];

    int is_no_arg = 0, is_one_arg = 0;
    for (int i = 0; no_arg[i] != NULL; i++)
        if (strcmp(cmd, no_arg[i]) == 0) { is_no_arg = 1; break; }
    for (int i = 0; one_arg[i] != NULL; i++)
        if (strcmp(cmd, one_arg[i]) == 0) { is_one_arg = 1; break; }

    if ((is_no_arg && argc != 2) || (is_one_arg && argc != 3) ||
        (!is_no_arg && !is_one_arg)) {
        fprintf(stderr, "synotoolbox-helper: rejected '%s' with %d argument(s)\n",
                cmd, argc - 2);
        return 1;
    }

    /* setuid binary gives us euid=0; promote ruid too so the exec'd
     * script is genuinely root, not just effectively root. */
    if (setuid(0) != 0) {
        perror("synotoolbox-helper: setuid(0) failed");
        return 1;
    }

    /* Sanitize environment: fixed PATH, no inherited surprises. */
    if (clearenv() != 0) {
        fprintf(stderr, "synotoolbox-helper: clearenv failed\n");
        return 1;
    }
    setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/syno/bin:/usr/syno/sbin", 1);
    setenv("HOME", "/root", 1);

    if (argc == 2) {
        execl(TARGET_SCRIPT, TARGET_SCRIPT, cmd, (char *)NULL);
    } else {
        execl(TARGET_SCRIPT, TARGET_SCRIPT, cmd, argv[2], (char *)NULL);
    }

    perror("synotoolbox-helper: execl failed");
    return 1;
}