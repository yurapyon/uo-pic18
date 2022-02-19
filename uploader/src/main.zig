const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
});
const Forth = @import("forth/lib.zig");

//

const pic18_base = @embedFile("pic18-base.fth");

//

const SerialError = error{
    NoTerminfo,
    CantSetTerminfo,
} || File.OpenError;

const allocator = std.heap.c_allocator;
const port = "/dev/ttyACM0";
const baudrate = 19200;

var vm: Forth.VM = undefined;
var working_file: ?[:0]u8 = null;
var last_load: []u8 = undefined;
var serial: File = undefined;

// TODO get rid of these and just use the slices
var progmem_addr: usize = undefined;
var progmem_len: usize = undefined;
var eeprom_addr: usize = undefined;
var eeprom_len: usize = undefined;
var config_addr: usize = undefined;

var progmem: []u8 = undefined;
var eeprom: []u8 = undefined;
var config: []u8 = undefined;
var config_mask: usize = undefined;

fn openSerial() SerialError!File {
    // TODO open flags are different in master and maybe 0.9.1
    const f = try std.fs.openFileAbsolute(port, .{
        .read = true,
        .write = true,
        .lock_nonblocking = true,
    });
    errdefer f.close();

    const baud: c_uint = switch (baudrate) {
        4800 => c.B4800,
        9600 => c.B9600,
        19200 => c.B19200,
        38400 => c.B38400,
        57600 => c.B57600,
        115200 => c.B115200,
        else => c.B9600,
    };

    var tios: c.termios = undefined;

    if (c.tcgetattr(f.handle, &tios) != 0) {
        return error.NoTerminfo;
    }

    _ = c.cfsetispeed(&tios, baud);
    _ = c.cfsetospeed(&tios, baud);

    // 8nX, minimal flow control, raw
    c.cfmakeraw(&tios);

    // 1 stop bit
    tios.c_cflag &= ~@as(c_uint, c.CSTOPB);

    // no flow control
    tios.c_cflag &= ~@as(c_uint, c.CRTSCTS);
    tios.c_iflag &= ~@as(c_uint, c.IXOFF | c.IXANY);

    // turn on read
    tios.c_cflag |= c.CREAD;

    // wait for one char before returning from a read on this fd
    // note: vtime is in 0.1 secs
    tios.c_cc[c.VMIN] = 0;
    tios.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(f.handle, c.TCSAFLUSH, &tios) != 0) {
        return error.CantSetTerminfo;
    }

    return f;
}

fn transmit() !void {
    std.debug.print("transmitting...\n", .{});

    const info_buf = [_]u8{
        0, // ignored byte
        @truncate(u8, progmem.len >> 16),
        @truncate(u8, progmem.len >> 8),
        @truncate(u8, progmem.len),
        @truncate(u8, eeprom.len >> 8),
        @truncate(u8, eeprom.len),
        @truncate(u8, config_mask >> 8),
        @truncate(u8, config_mask),
    };

    _ = try serial.write(&info_buf);

    const pm = progmem;
    _ = try serial.write(pm);
    std.debug.print("{b} {b} {b} {b}\n", .{
        pm[0],
        pm[1],
        pm[2],
        pm[3],
    });

    //     // TODO unexpected necessary [1]u8
    //     var buf: [1]u8 = .{0};
    //
    //     _ = try serial.write(&buf);
    //     std.debug.print("write: {}", .{buf[0]});
    //
    //     while (true) {
    //         const read = try serial.read(&buf);
    //         if (read == 1) {
    //             break;
    //         }
    //     }
    //     std.debug.print("read: {}\n", .{buf[0]});
    //     // _ = c.usleep(50000);
    //
    //     std.debug.print("ok\n\n", .{});
}

fn readFile(filename: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer file.close();
    return file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn loadWorkingFile() Forth.VM.Error!void {
    std.debug.print("loading working file...\n", .{});
    last_load = readFile(working_file.?) catch {
        std.debug.print("working file read error\n", .{});
        return error.Panic;
    };
    try vm.interpretBuffer(last_load);
    std.debug.print("\n", .{});
    progmem_len = try vmInterpretPopTop(usize, "progmem-here");
    eeprom_len = try vmInterpretPopTop(usize, "eeprom-here");
    config_mask = try vmInterpretPopTop(usize, "config-mask");
    std.debug.print("progmem: {} ({} Words)\neeprom:  {}\nconfig mask: 0b{b:0>16}\n", .{
        progmem_len,
        progmem_len / 2,
        eeprom_len,
        config_mask,
    });
    progmem.len = progmem_len;
    eeprom.len = eeprom_len;
    std.debug.print("ok\n\n", .{});
}

fn startRepl() Forth.VM.Error!void {
    vm.source_user_input = Forth.VM.forth_true;
    try vm.refill();
    try vm.drop();
    try vm.interpret();
}

fn reloadWorkingFile(_: *Forth.VM) Forth.VM.Error!void {
    allocator.free(last_load);
    try vm.interpretBuffer("0 to progmem-here");
    try vm.interpretBuffer("0 to eeprom-here");

    try loadWorkingFile();
    transmit() catch {
        std.debug.print("transmit error\n", .{});
        return error.Panic;
    };
    try startRepl();
}

fn vmInterpretPopTop(comptime T: type, buf: []const u8) Forth.VM.Error!T {
    try vm.interpretBuffer(buf);
    return @intCast(T, try vm.pop());
}

pub fn main() anyerror!void {
    vm = try Forth.VM.init(allocator);
    defer vm.deinit();

    std.debug.print("loading pic18 base...\n", .{});
    vm.interpretBuffer(pic18_base) catch |err| switch (err) {
        error.WordNotFound => {
            std.debug.print("word not found: {s}\n", .{vm.word_not_found});
            return err;
        },
        else => return err,
    };

    try vm.createBuiltin("reload", 0, &reloadWorkingFile);

    progmem_addr = try vmInterpretPopTop(usize, "progmem");
    eeprom_addr = try vmInterpretPopTop(usize, "eeprom");
    config_addr = try vmInterpretPopTop(usize, "config");
    std.debug.print("progmem: 0x{x}\neeprom:  0x{x}\nconfig:  0x{x}\n", .{
        progmem_addr,
        eeprom_addr,
        config_addr,
    });
    progmem.ptr = @intToPtr([*]u8, progmem_addr);
    eeprom.ptr = @intToPtr([*]u8, eeprom_addr);
    config.ptr = @intToPtr([*]u8, config_addr);
    config.len = 10;
    std.debug.print("ok\n\n", .{});

    var i: usize = 0;
    var args = std.process.args();
    while (args.next(allocator)) |arg_err| {
        const arg = try arg_err;
        if (i == 1) {
            working_file = arg;
        } else {
            allocator.free(arg);
        }
        i += 1;
    }

    if (working_file) |_| {} else {
        std.debug.print("please specify working file\n", .{});
        return;
    }

    defer allocator.free(working_file.?);

    std.debug.print("checking working file...\nworking_file: {s}\n", .{working_file});
    // TODO check file exists
    std.debug.print("ok\n\n", .{});

    std.debug.print("connecting to programmer...\nport: {s}\nbaudrate: {}\n", .{ port, baudrate });
    // TODO catch error here
    serial = try openSerial();
    defer serial.close();
    std.debug.print("ok\n\n", .{});

    std.debug.print("waiting for reset...\n", .{});
    _ = c.usleep(2000000);
    std.debug.print("ok\n\n", .{});

    try loadWorkingFile();
    defer allocator.free(last_load);

    try transmit();
    while (true) {
        startRepl() catch |err| {
            switch (err) {
                error.WordNotFound => {
                    std.debug.print("word not found: {s}\n", .{vm.word_not_found});
                },
                else => {
                    std.debug.print("/////////\nerror: {}\n\n", .{err});
                },
            }
            continue;
        };
        break;
    }
}
