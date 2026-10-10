package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.model.Position;
import com.genymobile.scrcpy.model.Point;
import java.io.DataInputStream;
import java.io.IOException;

/** Version 1 of the private 34-byte Scrcpy Remote drawing message. */
public final class StylusPacket {
    public final int action;
    public final int tool;
    public final Position position;
    public final float pressure;
    public final float tilt;
    public final float orientation;
    public final int buttons;
    public final long timestampUs;

    private StylusPacket(int action, int tool, Position position, float pressure,
            float tilt, float orientation, int buttons, long timestampUs) {
        this.action = action;
        this.tool = tool;
        this.position = position;
        this.pressure = pressure;
        this.tilt = tilt;
        this.orientation = orientation;
        this.buttons = buttons;
        this.timestampUs = timestampUs;
    }

    public static StylusPacket read(DataInputStream input) throws IOException {
        int version = input.readUnsignedByte();
        if (version != 1) {
            throw new ControlProtocolException("Unsupported stylus protocol version: " + version);
        }
        int action = input.readUnsignedByte();
        int tool = input.readUnsignedByte();
        int x = input.readInt();
        int y = input.readInt();
        int width = input.readUnsignedShort();
        int height = input.readUnsignedShort();
        float pressure = input.readUnsignedShort() / 65535f;
        float tilt = (float) (input.readUnsignedShort() / 65535.0 * Math.PI / 2);
        float orientation = (float) (input.readShort() / 32767.0 * Math.PI);
        int buttons = input.readInt();
        long timestampUs = input.readLong();
        if (!(action == 0 || action == 1 || action == 2 || action == 3 || action == 7 || action == 9 || action == 10)
                || tool < 1 || tool > 4 || width == 0 || height == 0 || timestampUs < 0) {
            throw new ControlProtocolException("Invalid stylus packet");
        }
        return new StylusPacket(action, tool, new Position(x, y, width, height), pressure, tilt,
                Math.max(-(float) Math.PI, orientation), buttons & (1 | 2 | 32 | 64), timestampUs);
    }

    // Apply server-side crop/rotation/reflection to the axis as well as the tip.
    // Sampling a long direction vector keeps pixel rounding insignificant.
    public float mappedOrientation(PositionMapper mapper) {
        Point point = position.getPoint();
        Position direction = new Position(point.getX() + (int) Math.round(Math.sin(orientation) * 1024),
                point.getY() - (int) Math.round(Math.cos(orientation) * 1024),
                position.getScreenSize().getWidth(), position.getScreenSize().getHeight());
        Point start = mapper.map(position);
        Point end = mapper.map(direction);
        if (start == null || end == null) { return orientation; }
        return (float) Math.atan2(end.getX() - start.getX(), start.getY() - end.getY());
    }
}
