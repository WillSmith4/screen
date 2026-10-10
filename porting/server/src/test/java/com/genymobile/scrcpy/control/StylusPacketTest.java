package com.genymobile.scrcpy.control;

import org.junit.Test;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.nio.file.Files;
import java.nio.file.Paths;
import static org.junit.Assert.*;

public class StylusPacketTest {
    private byte[] fixture() throws Exception {
        return Files.readAllBytes(Paths.get(System.getenv("STYLUS_FIXTURE")));
    }

    @Test public void readsClientFixtureAndFollowingStockMessage() throws Exception {
        ByteArrayOutputStream stream = new ByteArrayOutputStream();
        stream.write(fixture());
        stream.write(ControlMessage.TYPE_ROTATE_DEVICE);
        ControlMessageReader reader = new ControlMessageReader(new ByteArrayInputStream(stream.toByteArray()));
        ControlMessage msg = reader.read();
        assertEquals(128, msg.getType());
        StylusPacket p = msg.getStylus();
        assertEquals(2, p.action);
        assertEquals(4, p.tool);
        assertEquals(123456, p.position.getPoint().getX());
        assertEquals(-42, p.position.getPoint().getY());
        assertEquals(2160, p.position.getScreenSize().getWidth());
        assertEquals(3840, p.position.getScreenSize().getHeight());
        assertEquals(0.5, p.pressure, 0.00002);
        assertEquals(Math.PI / 4, p.tilt, 0.00003);
        assertEquals(-Math.PI / 2, p.orientation, 0.0001);
        assertEquals(32, p.buttons);
        assertEquals(0x0123456789ABCDEFL, p.timestampUs);
        assertEquals(ControlMessage.TYPE_ROTATE_DEVICE, reader.read().getType());
    }

    @Test(expected = ControlProtocolException.class) public void rejectsUnknownVersion() throws Exception {
        byte[] data = fixture(); data[1] = 2;
        new ControlMessageReader(new ByteArrayInputStream(data)).read();
    }
    @Test(expected = ControlProtocolException.class) public void rejectsInvalidTool() throws Exception {
        byte[] data = fixture(); data[3] = 99;
        new ControlMessageReader(new ByteArrayInputStream(data)).read();
    }
    @Test(expected = EOFException.class) public void rejectsTruncatedPacket() throws Exception {
        byte[] data = fixture();
        new ControlMessageReader(new ByteArrayInputStream(data, 0, data.length - 1)).read();
    }
}
