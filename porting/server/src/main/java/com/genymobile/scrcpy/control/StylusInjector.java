package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.device.Device;
import com.genymobile.scrcpy.model.Point;
import com.genymobile.scrcpy.wrappers.InputManager;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;

/** Independent state: normal scrcpy finger and mouse injection is unchanged. */
final class StylusInjector {
    private final MotionEvent.PointerProperties[] properties = {new MotionEvent.PointerProperties()};
    private final MotionEvent.PointerCoords[] coords = {new MotionEvent.PointerCoords()};
    private boolean down;
    private boolean hovering;
    private int displayId;
    private int source;
    private int buttons;
    private long downTime;
    private long clientStartUs;
    private long serverStart;
    private long lastEventTime;

    public void cancel() {
        long now = SystemClock.uptimeMillis();
        if (down) {
            coords[0].pressure = 0;
            send(MotionEvent.ACTION_CANCEL, now, 0, 0);
        }
        if (hovering) { send(MotionEvent.ACTION_HOVER_EXIT, now, 0, 0); }
        down = false;
        hovering = false;
        buttons = 0;
    }

    public boolean inject(StylusPacket packet, Point point, int targetDisplayId) {
        int action = packet.action;
        long now = SystemClock.uptimeMillis();
        if ((down || hovering) && (targetDisplayId != displayId || packet.tool != properties[0].toolType)) { cancel(); }
        if (action == MotionEvent.ACTION_DOWN) {
            cancel();
            down = true;
            downTime = now;
            clientStartUs = packet.timestampUs;
            serverStart = now;
            lastEventTime = now;
        } else if ((action == MotionEvent.ACTION_MOVE || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) && !down) {
            return false;
        }
        displayId = targetDisplayId;
        properties[0].id = 0;
        properties[0].toolType = packet.tool;
        source = packet.tool == MotionEvent.TOOL_TYPE_MOUSE ? InputDevice.SOURCE_MOUSE
                : packet.tool == MotionEvent.TOOL_TYPE_FINGER ? InputDevice.SOURCE_TOUCHSCREEN : InputDevice.SOURCE_STYLUS;
        coords[0].clear();
        coords[0].x = point.getX();
        coords[0].y = point.getY();
        coords[0].pressure = down && action != MotionEvent.ACTION_UP && action != MotionEvent.ACTION_CANCEL ? packet.pressure : 0;
        coords[0].size = 0.01f;
        coords[0].setAxisValue(MotionEvent.AXIS_TILT, packet.tilt);
        coords[0].setAxisValue(MotionEvent.AXIS_ORIENTATION, packet.orientation);
        long time = down ? Math.min(now, serverStart + Math.max(0, (packet.timestampUs - clientStartUs) / 1000)) : now;
        time = Math.max(lastEventTime, time);
        lastEventTime = time;
        int nextButtons = source == InputDevice.SOURCE_TOUCHSCREEN ? 0 : packet.buttons;
        if (action == MotionEvent.ACTION_HOVER_ENTER) {
            if (down || source == InputDevice.SOURCE_TOUCHSCREEN) { return false; }
            hovering = true;
        } else if (action == MotionEvent.ACTION_HOVER_MOVE && !hovering) {
            if (down || source == InputDevice.SOURCE_TOUCHSCREEN) { return false; }
            send(MotionEvent.ACTION_HOVER_ENTER, time, nextButtons, 0);
            hovering = true;
        } else if (action == MotionEvent.ACTION_HOVER_EXIT) {
            if (!hovering) { return false; }
            hovering = false;
        }
        int released = buttons & ~nextButtons;
        int pressed = nextButtons & ~buttons;
        if (released != 0) { send(MotionEvent.ACTION_BUTTON_RELEASE, time, nextButtons, released); }
        boolean result = send(action, time, nextButtons, 0);
        if (pressed != 0) { send(MotionEvent.ACTION_BUTTON_PRESS, time, nextButtons, pressed); }
        buttons = nextButtons;
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            down = false;
            buttons = 0;
        }
        return result;
    }

    private boolean send(int action, long time, int buttonState, int actionButton) {
        MotionEvent event = MotionEvent.obtain(downTime, time, action, 1, properties, coords,
                0, buttonState, 1, 1, -1, 0, source, 0);
        try {
            if (actionButton != 0 && !InputManager.setActionButton(event, actionButton)) { return false; }
            return Device.injectEvent(event, displayId, Device.INJECT_MODE_ASYNC);
        } finally { event.recycle(); }
    }
}
