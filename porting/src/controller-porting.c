//
//  controller-porting.c
//  scrcpy-mobile
//
//  Created by Ethan on 2022/6/2.
//

// include time
#include <sys/time.h>

#define sc_controller_push_msg(...)     sc_controller_push_msg_hijack(__VA_ARGS__)

#include "controller.c"

#undef sc_controller_push_msg

#include "control-coalescing.h"

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))

// Defined in screen-porting.m
#import "screen.h"
struct sc_screen *
sc_screen_current_screen(struct sc_screen *screen);

// Fix negative point values and larger than screen size
bool sc_controller_push_msg(struct sc_controller *controller,
                            const struct sc_control_msg *incoming) {
    struct sc_control_msg normalized = *incoming;
    struct sc_control_msg *msg = &normalized;
    if (msg->type == SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT) {
      	// log current touch event with time and position
        struct timeval tv;
        gettimeofday(&tv, NULL);
        // printf("inject_touch_event: %ld.%06ld, x=%d, y=%d\n", tv.tv_sec, tv.tv_usec,
        //       msg->inject_touch_event.position.point.x, msg->inject_touch_event.position.point.y);

        // x/y is negative
        msg->inject_touch_event.position.point.x = MAX(msg->inject_touch_event.position.point.x, 0);;
        msg->inject_touch_event.position.point.y = MAX(msg->inject_touch_event.position.point.y, 0);
        
        // x/y exceed max frame size
        struct sc_size screen_size = msg->inject_touch_event.position.screen_size;
        if (screen_size.width && screen_size.height) {
			msg->inject_touch_event.position.point.x = MIN(msg->inject_touch_event.position.point.x, screen_size.width - 1);
            msg->inject_touch_event.position.point.y = MIN(msg->inject_touch_event.position.point.y, screen_size.height - 1);
        }
    }
    
    // Coalesce before the upstream queue limit drops NEW coordinates and
    // leaves a backlog of OLD ones. The consumer uses the same mutex.
    sc_mutex_lock(&controller->mutex);
    bool replaced = sc_touch_replace_pending(controller->queue.data,
        controller->queue.cap, controller->queue.origin,
        sc_vecdeque_size(&controller->queue), msg);
    sc_mutex_unlock(&controller->mutex);
    return replaced || sc_controller_push_msg_hijack(controller, msg);
}
