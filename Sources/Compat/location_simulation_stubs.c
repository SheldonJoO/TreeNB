/*
 * location_simulation_stubs.c
 * TreeNB —— IDevice 定位模拟符号补齐
 *
 * openSSS 的 minimuxer/DeviceGateway 把 IDevice.xcframework 的本地路径换成了
 * 官方 release 二进制（见 patch_upstream.sh A6）。上游注释明确说明该 release
 * 编译时没开 location_simulation feature：头文件有声明，.a 里没有定义，
 * 于是主 App 链接时报 `_location_simulation_new/free/set/clear` undefined。
 *
 * 定位模拟不是 TreeNB 单包闭环（侧载 + 容器 + 小组件）的必需能力，
 * 这里提供无副作用的 C 桩：new 返回一个静态哑句柄，set/clear 报成功，
 * free 空操作。这样 IdeviceGateway 上层不会崩，也不会误以为拿到真实服务。
 * 若将来换成带 location_simulation 的 xcframework，删掉本文件即可。
 */

#include <stddef.h>

typedef struct {
    int reserved;
} TNBLocationSimulationDummy;

static TNBLocationSimulationDummy tnb_location_simulation_dummy = {0};

void *location_simulation_new(void *server, void **handle) {
    (void)server;
    if (handle) {
        *handle = &tnb_location_simulation_dummy;
    }
    return NULL; /* NULL error = success */
}

void location_simulation_free(void *handle) {
    (void)handle;
}

void *location_simulation_set(void *handle, double latitude, double longitude) {
    (void)handle;
    (void)latitude;
    (void)longitude;
    return NULL;
}

void *location_simulation_clear(void *handle) {
    (void)handle;
    return NULL;
}
