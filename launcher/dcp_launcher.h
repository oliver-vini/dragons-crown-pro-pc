/* The launcher, called by the loader before the guest and the game window exist. */
#ifndef DCP_LAUNCHER_H
#define DCP_LAUNCHER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *app0;          /* prepared game folder (/app0) */
    const char *image_dir;     /* folder with boot.bin, content.bin and image.json */
    const char *user_dir;      /* user data; dcp.ini lives here unless settings_file is set */
    const char *settings_file; /* NULL: <user_dir>/dcp.ini */
    const char *logs_dir;      /* NULL when unknown */
    int skip_once;             /* --dcp-skip-launcher: do not show it unless the game files are not ready */
    int force_show;            /* --launcher: show it even when "Show this launcher" is off, like holding Shift */
} DcpLauncherConfig;

/* NULL asks for the default, which is relative to the executable (launcher/paths.h). */
typedef struct {
    const char *boot;
    const char *content_profile;
    const char *app0;
    const char *user_dir;
    const char *logs_dir;
} DcpPathRequest;

typedef struct {
    char boot[4096];
    char content_profile[4096];
    char app0[4096];
    char image_dir[4096];
    char user_dir[4096];
    char logs_dir[4096];
} DcpPaths;

/* 0 when the executable's folder is unknown or a path does not fit. */
int dcp_resolve_paths(const DcpPathRequest *request, DcpPaths *paths);

/* Index into dcp_resolutions (dcp_resolution.h) of the render_resolution in the settings file; 0 (native) when the
 * file or the value is missing. */
int dcp_render_resolution(const char *settings_file);

/* Fills `names` with the distinct names of the Vulkan devices the renderer can use and returns how many; enumerates
 * only, no device is created. */
int dcp_gpu_names(char (*names)[256], int max);

/* 1 when Vulkan can run the renderer. Otherwise logs why, shows it in an error window until the player closes it (on
 * stderr only without a display) and returns 0. */
int dcp_check_vulkan(void);

/* Builds boot.bin, content.bin and image.json in `out` from the prepared game folder `app0` (UTF-8 paths). 0 on
 * success; otherwise 1 and the reason in `error`. */
int dcp_build_boot_image(const char *app0, const char *out, char *error, size_t error_size);

typedef enum { DCP_LAUNCHER_PLAY = 0, DCP_LAUNCHER_QUIT = 1 } DcpLauncherResult;

/* Shows the launcher when its rules say so (game files not ready, "Show this launcher" on, or Shift held) and returns
 * once the player pressed Play or quit. Returns DCP_LAUNCHER_PLAY at once when it is not shown. */
DcpLauncherResult dcp_launcher_run(const DcpLauncherConfig *config);

#ifdef __cplusplus
}
#endif

#endif
