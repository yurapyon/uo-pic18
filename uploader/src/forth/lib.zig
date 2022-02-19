const std = @import("std");
const Allocator = std.mem.Allocator;

//;

// TODO
// better error reporting
// wordlists maybe
// have a way to notify on overwrite name
//    hashtable
//    just do find on the word name before you define
// 2c, 4c,
// base.fs, find spots where errors are ignored and abort"
//   error handling in general
//   error ( num -- ) which passes error num to zig
//     can be used with zig enums
// bye is needed twice to quit for some reason

// ===

// stack pointers point to 1 beyond the top of the stack
//   should i keep it this way?

// state == forth_true in compilation state

pub const VM = struct {
    const Self = @This();

    // TODO this can take options for memory size, float size, etc

    pub const Error = error{
        StackUnderflow,
        StackOverflow,
        StackIndexOutOfRange,

        ReturnStackUnderflow,
        ReturnStackOverflow,
        ReturnStackIndexOutOfRange,

        FloatStackUnderflow,
        FloatStackOverflow,
        FloatStackIndexOutOfRange,

        WordTooLong,
        WordNotFound,
        InvalidNumber,
        InvalidFloat,
        ExecutionError,
        AlignmentError,

        EndOfInput,
        Panic,
    } || Allocator.Error;

    pub const baseLib = @embedFile("base.fs");

    // TODO make sure cell is u64
    pub const Cell = usize;
    pub const SCell = isize;
    pub const QuarterCell = u16;
    pub const HalfCell = u32;
    pub const Builtin = fn (self: *Self) Error!void;
    pub const Float = f32;

    pub const forth_false: Cell = 0;
    pub const forth_true = ~forth_false;

    // TODO use doBuiltin dummy function address
    const builtin_fn_id = 0;

    const word_max_len = std.math.maxInt(u8);
    const word_immediate_flag = 0x2;
    const word_hidden_flag = 0x1;

    const mem_size = 4 * 1024 * 1024;
    const stack_size = 192 * @sizeOf(Cell);
    const rstack_size = 64 * @sizeOf(Cell);
    // TODO these two need to be cell aligned
    const fstack_size = 64 * @sizeOf(Float);
    const input_buffer_size = 128;

    const stack_start = 0;
    const rstack_start = stack_start + stack_size;
    const fstack_start = rstack_start + rstack_size;
    const input_buffer_start = fstack_start + fstack_size;
    const dictionary_start = input_buffer_start + input_buffer_size;

    const file_read_flag = 0x1;
    const file_write_flag = 0x2;
    const file_included_max_size = 64 * 1024;

    pub const ParseNumberResult = union(enum) {
        Float: Float,
        Cell: Cell,
    };

    allocator: Allocator,

    // execution
    last_next: Cell,
    next: Cell,
    curr_xt: Cell,
    should_bye: bool,
    should_quit: bool,

    lit_address: Cell,
    litFloat_address: Cell,
    docol_address: Cell,
    quit_address: Cell,

    mem: []u8,
    latest: Cell,
    here: Cell,
    base: Cell,
    state: Cell,
    sp: Cell,
    rsp: Cell,
    fsp: Cell,

    source_user_input: Cell,
    source_ptr: Cell,
    source_len: Cell,
    source_in: Cell,

    stack: [*]Cell,
    rstack: [*]Cell,
    fstack: [*]Float,
    input_buffer: [*]u8,
    dictionary: [*]u8,

    word_not_found: []u8,

    pub fn init(allocator: Allocator) Error!Self {
        var ret: Self = undefined;

        ret.allocator = allocator;
        ret.last_next = 0;
        ret.next = 0;

        ret.mem = try allocator.allocWithOptions(u8, mem_size, @alignOf(Cell), null);
        ret.stack = @ptrCast([*]Cell, @alignCast(@alignOf(Cell), &ret.mem[stack_start]));
        ret.rstack = @ptrCast([*]Cell, @alignCast(@alignOf(Cell), &ret.mem[rstack_start]));
        ret.fstack = @ptrCast([*]Float, @alignCast(@alignOf(Cell), &ret.mem[fstack_start]));
        ret.input_buffer = @ptrCast([*]u8, &ret.mem[input_buffer_start]);
        ret.dictionary = @ptrCast([*]u8, &ret.mem[dictionary_start]);

        // init vars
        ret.latest = 0;
        ret.here = @ptrToInt(ret.dictionary);
        ret.base = 10;
        ret.state = forth_false;
        ret.sp = @ptrToInt(ret.stack);
        ret.rsp = @ptrToInt(ret.rstack);
        ret.fsp = @ptrToInt(ret.fstack);

        try ret.initBuiltins();
        ret.interpretBuffer(baseLib) catch |err| switch (err) {
            error.WordNotFound => {
                std.debug.print("word not found: {s}\n", .{ret.word_not_found});
                return err;
            },
            else => return err,
        };

        ret.source_user_input = forth_true;
        return ret;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.mem);
    }

    fn initBuiltins(self: *Self) Error!void {
        try self.createBuiltin("docol", 0, &docol);
        self.docol_address = wordHeaderCodeFieldAddress(self.latest);
        try self.createBuiltin("exit", 0, &exit_);
        try self.createBuiltin("lit", 0, &lit);
        self.lit_address = wordHeaderCodeFieldAddress(self.latest);
        try self.createBuiltin("litfloat", 0, &litFloat);
        self.litFloat_address = wordHeaderCodeFieldAddress(self.latest);
        try self.createBuiltin("execute", 0, &executeForth);
        try self.createBuiltin("quit", 0, &quit);
        self.quit_address = wordHeaderCodeFieldAddress(self.latest);
        try self.createBuiltin("bye", 0, &bye);

        try self.createBuiltin("mem", 0, &memStart);
        try self.createBuiltin("mem-size", 0, &memSize);
        try self.createBuiltin("dictionary", 0, &dictionaryStart);
        try self.createBuiltin("state", 0, &state);
        try self.createBuiltin("latest", 0, &latest);
        try self.createBuiltin("here", 0, &here);
        try self.createBuiltin("base", 0, &base);
        try self.createBuiltin("s0", 0, &s0);
        try self.createBuiltin("sp", 0, &sp);
        try self.createBuiltin("sp@", 0, &spFetch);
        try self.createBuiltin("sp!", 0, &spStore);
        try self.createBuiltin("rs0", 0, &rs0);
        try self.createBuiltin("rsp", 0, &rsp);
        try self.createBuiltin("fs0", 0, &fs0);
        try self.createBuiltin("fsp", 0, &fsp);

        try self.createBuiltin("dup", 0, &dup);
        try self.createBuiltin("?dup", 0, &dupMaybe);
        try self.createBuiltin("drop", 0, &drop);
        try self.createBuiltin("swap", 0, &swap);
        try self.createBuiltin("over", 0, &over);
        try self.createBuiltin("tuck", 0, &tuck);
        try self.createBuiltin("nip", 0, &nip);
        try self.createBuiltin("rot", 0, &rot);
        try self.createBuiltin("-rot", 0, &nrot);
        try self.createBuiltin("pick", 0, &pick);
        try self.createBuiltin("2swap", 0, &swap2);

        try self.createBuiltin(">r", 0, &toR);
        try self.createBuiltin("r>", 0, &fromR);
        try self.createBuiltin("r@", 0, &rFetch);

        try self.createBuiltin("define", 0, &define);
        try self.createBuiltin("word", 0, &word);
        try self.createBuiltin("next-char", 0, &nextCharForth);
        try self.createBuiltin("find", 0, &find);
        try self.createBuiltin("@", 0, &fetch);
        try self.createBuiltin("!", 0, &store);
        try self.createBuiltin(",", 0, &comma);
        try self.createBuiltin("c@", 0, &fetchByte);
        try self.createBuiltin("c!", 0, &storeByte);
        try self.createBuiltin("c,", 0, &commaByte);
        try self.createBuiltin("q@", 0, &fetchQuarter);
        try self.createBuiltin("q!", 0, &storeQuarter);
        try self.createBuiltin("q,", 0, &commaQuarter);
        try self.createBuiltin("h@", 0, &fetchHalf);
        try self.createBuiltin("h!", 0, &storeHalf);
        try self.createBuiltin("h,", 0, &commaHalf);
        try self.createBuiltin("'", 0, &tick);
        try self.createBuiltin("[']", word_immediate_flag, &bracketTick);
        try self.createBuiltin("[", word_immediate_flag, &lBracket);
        try self.createBuiltin("]", 0, &rBracket);

        try self.createBuiltin("flag,immediate", 0, &immediateFlag);
        try self.createBuiltin("flag,hidden", 0, &hiddenFlag);
        try self.createBuiltin("make-immediate", 0, &makeImmediate);
        try self.createBuiltin("hide", 0, &hide);

        try self.createBuiltin(">cfa", 0, &getCfa);
        try self.createBuiltin("branch", 0, &branch);
        try self.createBuiltin("0branch", 0, &zbranch);

        try self.createBuiltin("true", 0, &true_);
        try self.createBuiltin("false", 0, &false_);
        try self.createBuiltin("=", 0, &equal);
        try self.createBuiltin("<>", 0, &notEqual);
        try self.createBuiltin("<", 0, &lt);
        try self.createBuiltin(">", 0, &gt);
        try self.createBuiltin("u<", 0, &ult);
        try self.createBuiltin("u>", 0, &ugt);
        try self.createBuiltin("and", 0, &and_);
        try self.createBuiltin("or", 0, &or_);
        try self.createBuiltin("xor", 0, &xor);
        try self.createBuiltin("invert", 0, &invert);
        try self.createBuiltin("lshift", 0, &lshift);
        try self.createBuiltin("rshift", 0, &rshift);

        try self.createBuiltin("+", 0, &plus);
        try self.createBuiltin("-", 0, &minus);
        try self.createBuiltin("*", 0, &times);
        try self.createBuiltin("/mod", 0, &divMod);
        try self.createBuiltin("cell", 0, &cell);
        try self.createBuiltin("half", 0, &half);
        try self.createBuiltin(">number", 0, &parseNumberForth);
        try self.createBuiltin("+!", 0, &plusStore);

        try self.createBuiltin(".s", 0, &showStack);

        try self.createBuiltin("litstring", 0, &litString);
        try self.createBuiltin("type", 0, &type_);
        // try self.createBuiltin("key", 0, &key);
        // try self.createBuiltin("key?", 0, &keyAvailable);
        try self.createBuiltin("char", 0, &char);
        try self.createBuiltin("emit", 0, &emit);

        try self.createBuiltin("allocate", 0, &allocate);
        try self.createBuiltin("free", 0, &free_);
        // TODO resize
        try self.createBuiltin("cmove>", 0, &cmoveUp);
        try self.createBuiltin("cmove<", 0, &cmoveDown);
        try self.createBuiltin("mem=", 0, &memEql);

        // TODO float comparisons
        try self.createBuiltin("f.", 0, &fPrint);
        try self.createBuiltin("f+", 0, &fPlus);
        try self.createBuiltin("f-", 0, &fMinus);
        try self.createBuiltin("f*", 0, &fTimes);
        try self.createBuiltin("f/", 0, &fDivide);
        try self.createBuiltin("float", 0, &fSize);
        try self.createBuiltin("fsin", 0, &fSin);
        try self.createBuiltin("pi", 0, &pi);
        try self.createBuiltin("tau", 0, &tau);
        try self.createBuiltin("f@", 0, &fFetch);
        try self.createBuiltin("f!", 0, &fStore);
        try self.createBuiltin("f,", 0, &fComma);
        try self.createBuiltin("f+!", 0, &fPlusStore);
        try self.createBuiltin(">float", 0, &fParse);
        try self.createBuiltin("fdrop", 0, &fDrop);
        try self.createBuiltin("fdup", 0, &fDup);
        try self.createBuiltin("fswap", 0, &fSwap);
        try self.createBuiltin("f>s", 0, &fToS);
        try self.createBuiltin("s>f", 0, &sToF);

        try self.createBuiltin("r/o", 0, &fileRO);
        try self.createBuiltin("w/o", 0, &fileWO);
        try self.createBuiltin("r/w", 0, &fileRW);
        try self.createBuiltin("open-file", 0, &fileOpen);
        try self.createBuiltin("close-file", 0, &fileClose);
        try self.createBuiltin("file-size", 0, &fileSize);
        try self.createBuiltin("read-file", 0, &fileRead);
        try self.createBuiltin("read-line", 0, &fileReadLine);

        try self.createBuiltin("source-user-input", 0, &sourceUserInput);
        try self.createBuiltin("source-ptr", 0, &sourcePtr);
        try self.createBuiltin("source-len", 0, &sourceLen);
        try self.createBuiltin(">in", 0, &sourceIn);
        try self.createBuiltin("refill", 0, &refill);

        try self.createBuiltin("panic", 0, &panic_);
    }

    //;

    pub fn pop(self: *Self) Error!Cell {
        if (self.sp <= @ptrToInt(self.stack)) {
            return error.StackUnderflow;
        }
        self.sp -= @sizeOf(Cell);
        const ret = @intToPtr(*const Cell, self.sp).*;
        return ret;
    }

    pub fn push(self: *Self, val: Cell) Error!void {
        if (self.sp >= @ptrToInt(self.stack) + stack_size) {
            return error.StackOverflow;
        }
        @intToPtr(*Cell, self.sp).* = val;
        self.sp += @sizeOf(Cell);
    }

    pub fn sidx(self: *Self, val: Cell) Error!Cell {
        const ptr = self.sp - (val + 1) * @sizeOf(Cell);
        if (ptr < @ptrToInt(self.stack)) {
            return error.StackIndexOutOfRange;
        }
        return @intToPtr(*const Cell, ptr).*;
    }

    pub fn rpop(self: *Self) Error!Cell {
        if (self.rsp <= @ptrToInt(self.rstack)) {
            return error.ReturnStackUnderflow;
        }
        self.rsp -= @sizeOf(Cell);
        const ret = @intToPtr(*const Cell, self.rsp).*;
        return ret;
    }

    pub fn rpush(self: *Self, val: Cell) Error!void {
        if (self.rsp >= @ptrToInt(self.rstack) + rstack_size) {
            return error.ReturnStackOverflow;
        }
        @intToPtr(*Cell, self.rsp).* = val;
        self.rsp += @sizeOf(Cell);
    }

    // TODO ridx

    pub fn fpop(self: *Self) Error!Float {
        if (self.fsp <= @ptrToInt(self.fstack)) {
            return error.FloatStackUnderflow;
        }
        self.fsp -= @sizeOf(Float);
        const ret = @intToPtr(*const Float, self.fsp).*;
        return ret;
    }

    pub fn fpush(self: *Self, val: Float) Error!void {
        if (self.fsp >= @ptrToInt(self.fstack) + fstack_size) {
            return error.FloatStackOverflow;
        }
        @intToPtr(*Float, self.fsp).* = val;
        self.fsp += @sizeOf(Float);
    }

    // TODO fidx

    //;

    pub fn checkedRead(self: *Self, comptime T: type, addr: Cell) Error!T {
        _ = self;
        if (addr % @alignOf(T) != 0) return error.AlignmentError;
        return @intToPtr(*const T, addr).*;
    }

    // TODO handle masking the bits
    pub fn checkedWrite(
        self: *Self,
        comptime T: type,
        addr: Cell,
        val: T,
    ) Error!void {
        _ = self;
        if (addr % @alignOf(T) != 0) return error.AlignmentError;
        @intToPtr(*T, addr).* = val;
    }

    pub fn arrayAt(comptime T: type, addr: Cell, len: Cell) []T {
        var str: []T = undefined;
        str.ptr = @intToPtr([*]T, addr);
        str.len = len;
        return str;
    }

    pub fn alignAddr(comptime T: type, addr: Cell) Cell {
        const off_aligned = @alignOf(T) - (addr % @alignOf(T));
        return if (off_aligned == @alignOf(T)) addr else addr + off_aligned;
    }

    pub fn parseNumber(str: []const u8, base_: Cell) Error!Cell {
        var is_negative: bool = false;
        var read_at: usize = 0;
        var acc: Cell = 0;

        if (str[0] == '-') {
            is_negative = true;
            read_at += 1;
        } else if (str[0] == '+') {
            read_at += 1;
        }

        var effective_base = base_;
        if (str.len > 2) {
            if (std.mem.eql(u8, "0x", str[0..2])) {
                effective_base = 16;
                read_at += 2;
            } else if (std.mem.eql(u8, "0b", str[0..2])) {
                effective_base = 2;
                read_at += 2;
            }
        }

        while (read_at < str.len) : (read_at += 1) {
            const ch = str[read_at];
            const digit = switch (ch) {
                '0'...'9' => ch - '0',
                'A'...'Z' => ch - 'A' + 10,
                'a'...'z' => ch - 'a' + 10,
                else => return error.InvalidNumber,
            };
            if (digit > effective_base) return error.InvalidNumber;
            acc = acc * effective_base + digit;
        }

        return if (is_negative) 0 -% acc else acc;
    }

    pub fn parseFloat(str: []const u8) Error!Float {
        for (str) |ch| {
            switch (ch) {
                '0'...'9', '.', '+', '-' => {},
                else => return error.InvalidFloat,
            }
        }
        if (str.len == 1 and
            (str[0] == '+' or
            str[0] == '-' or
            str[0] == '.'))
        {
            return error.InvalidFloat;
        }
        return std.fmt.parseFloat(Float, str) catch {
            return error.InvalidFloat;
        };
    }

    pub fn pushString(self: *Self, str: []const u8) Error!void {
        try self.push(@ptrToInt(str.ptr));
        try self.push(str.len);
    }

    //;

    // word header is:
    // |        | | |  ...  |  ...  | ...
    //  ^        ^ ^ ^       ^       ^
    //  addr of  | | name    |       code
    //  previous | name_len  padding to @alignOf(Cell)
    //  word     flags

    // builtins are:
    // | WORD HEADER ... | builtin_fn_id | fn_ptr |

    // forth words are:
    // | WORD HEADER ... | DOCOL  | code ... | EXIT |

    // code is executed 'immediately' if the first cell in its cfa is builtin_fn_id

    pub fn createWordHeader(
        self: *Self,
        name: []const u8,
        flags: u8,
    ) Error!void {
        // TODO check word len isnt too long?
        self.here = alignAddr(Cell, self.here);
        const new_latest = self.here;
        try self.push(self.latest);
        try self.comma();
        try self.push(flags);
        try self.commaByte();
        try self.push(name.len);
        try self.commaByte();

        for (name) |ch| {
            try self.push(ch);
            try self.commaByte();
        }

        while ((self.here % @alignOf(Cell)) != 0) {
            try self.push(0);
            try self.commaByte();
        }

        self.latest = new_latest;
    }

    pub fn wordHeaderPrevious(addr: Cell) Cell {
        return @intToPtr(*const Cell, addr).*;
    }

    pub fn wordHeaderFlags(addr: Cell) *u8 {
        return @intToPtr(*u8, addr + @sizeOf(Cell));
    }

    pub fn wordHeaderName(addr: Cell) []u8 {
        var name: []u8 = undefined;
        name.ptr = @intToPtr([*]u8, addr + @sizeOf(Cell) + 2);
        name.len = @intToPtr(*u8, addr + @sizeOf(Cell) + 1).*;
        return name;
    }

    pub fn wordHeaderCodeFieldAddress(addr: Cell) Cell {
        const name = wordHeaderName(addr);
        const name_end_addr = @ptrToInt(name.ptr) + name.len;
        return alignAddr(Cell, name_end_addr);
    }

    pub fn createBuiltin(
        self: *Self,
        name: []const u8,
        flags: u8,
        func: *const Builtin,
    ) Error!void {
        try self.createWordHeader(name, flags);
        try self.push(builtin_fn_id);
        try self.comma();
        try self.push(@ptrToInt(func));
        try self.comma();
    }

    pub fn builtinFnPtrAddress(cfa: Cell) Cell {
        return cfa + @sizeOf(Cell);
    }

    pub fn builtinFnPtr(cfa: Cell) *const Builtin {
        const fn_ptr = @intToPtr(*const Cell, builtinFnPtrAddress(cfa)).*;
        return @intToPtr(*const Builtin, fn_ptr);
    }

    pub fn findWord(self: *Self, addr: Cell, len: Cell) Error!Cell {
        const name = arrayAt(u8, addr, len);

        var check = self.latest;
        while (check != 0) : (check = wordHeaderPrevious(check)) {
            const check_name = wordHeaderName(check);
            const flags = wordHeaderFlags(check).*;
            if (check_name.len != len) continue;
            if ((flags & word_hidden_flag) != 0) continue;

            var name_matches: bool = true;
            var i: usize = 0;
            for (name) |name_ch| {
                if (std.ascii.toUpper(check_name[i]) != std.ascii.toUpper(name_ch)) {
                    name_matches = false;
                    break;
                }
                i += 1;
            }

            if (name_matches) {
                break;
            }
        }

        if (check == 0) {
            self.word_not_found = name;
            return error.WordNotFound;
        } else {
            return check;
        }
    }

    // ===

    pub fn execute(self: *Self, xt: Cell) Error!void {
        // note: self.quit_address is just being used as a marker
        self.last_next = self.quit_address;
        self.next = self.quit_address;
        self.curr_xt = xt;
        var first = xt;

        self.should_bye = false;
        self.should_quit = false;
        while (!self.should_bye and !self.should_quit) {
            if (self.curr_xt == self.quit_address) {
                try self.quit();
                break;
            }
            if ((try self.checkedRead(Cell, first)) == builtin_fn_id) {
                const fn_ptr = builtinFnPtr(first);
                try fn_ptr.*(self);
            } else {
                self.last_next = self.next;
                self.next = first;
            }

            self.curr_xt = self.next;
            first = try self.checkedRead(Cell, self.curr_xt);
            self.next += @sizeOf(Cell);
        }
    }

    pub fn interpret(self: *Self) Error!void {
        self.should_bye = false;
        while (!self.should_bye) {
            try self.word();
            const word_len = try self.sidx(0);
            const word_addr = try self.sidx(1);
            if (word_len == 0) {
                _ = try self.pop();
                _ = try self.pop();
                try self.refill();
                const res = try self.pop();
                if (res == forth_false) {
                    self.should_bye = true;
                }
                continue;
            }

            try self.find();

            const was_found = try self.pop();
            const addr = try self.pop();
            const is_compiling = self.state != forth_false;
            if (was_found == forth_true) {
                const flags = wordHeaderFlags(addr).*;
                const is_immediate = (flags & word_immediate_flag) != 0;
                const xt = wordHeaderCodeFieldAddress(addr);
                if (is_compiling and !is_immediate) {
                    try self.push(xt);
                    try self.comma();
                } else {
                    try self.execute(xt);
                }
            } else {
                var str = arrayAt(u8, word_addr, word_len);
                if (parseNumber(str, self.base) catch null) |num| {
                    if (is_compiling) {
                        try self.push(self.lit_address);
                        try self.comma();
                        try self.push(num);
                        try self.comma();
                    } else {
                        try self.push(num);
                    }
                } else if (parseFloat(str) catch null) |fl| {
                    if (is_compiling) {
                        try self.push(self.litFloat_address);
                        try self.comma();
                        try self.fpush(fl);
                        try self.fComma();
                        self.here = alignAddr(Cell, self.here);
                    } else {
                        try self.fpush(fl);
                    }
                } else {
                    self.word_not_found = str;
                    return error.WordNotFound;
                }
            }
        }
    }

    pub fn nextChar(self: *Self) Error!u8 {
        if (self.source_in >= self.source_len) {
            return error.EndOfInput;
        }
        const ch = self.checkedRead(u8, self.source_ptr + self.source_in);
        self.source_in += 1;
        return ch;
    }

    pub fn interpretBuffer(self: *Self, buf: []const u8) Error!void {
        self.source_user_input = VM.forth_false;
        self.source_ptr = @ptrToInt(buf.ptr);
        self.source_len = buf.len;
        self.source_in = 0;
        try self.interpret();
    }

    // builtins

    pub fn word(self: *Self) Error!void {
        var ch: u8 = ' ';
        while (ch == ' ' or ch == '\n') {
            ch = self.nextChar() catch |err| switch (err) {
                error.EndOfInput => {
                    try self.push(0);
                    try self.push(0);
                    return;
                },
                else => return err,
            };
        }

        const start_idx = self.source_in - 1;
        var len: Cell = 1;

        while (true) {
            ch = self.nextChar() catch |err| switch (err) {
                error.EndOfInput => break,
                else => return err,
            };

            if (ch == ' ' or ch == '\n') {
                break;
            }

            if (len >= word_max_len) {
                return error.WordTooLong;
            }

            len += 1;
        }

        try self.push(self.source_ptr + start_idx);
        try self.push(len);
    }

    pub fn nextCharForth(self: *Self) Error!void {
        try self.push(try self.nextChar());
    }

    pub fn docol(self: *Self) Error!void {
        try self.rpush(self.last_next);
        self.next = self.curr_xt + @sizeOf(Cell);
    }

    pub fn exit_(self: *Self) Error!void {
        self.next = try self.rpop();
    }

    pub fn lit(self: *Self) Error!void {
        try self.push(try self.checkedRead(Cell, self.next));
        self.next += @sizeOf(Cell);
    }

    pub fn litFloat(self: *Self) Error!void {
        try self.fpush(try self.checkedRead(Float, self.next));
        self.next += @sizeOf(Cell);
    }

    pub fn executeForth(self: *Self) Error!void {
        const xt = try self.pop();
        const first = @intToPtr(*Cell, xt).*;
        if (first == builtin_fn_id) {
            try builtinFnPtr(xt).*(self);
        } else if (first == self.docol_address) {
            try self.rpush(self.next);
            self.next = xt + @sizeOf(Cell);
        } else {
            return error.ExecutionError;
        }
    }

    pub fn quit(self: *Self) Error!void {
        self.rsp = @ptrToInt(self.rstack);
        self.should_quit = true;
    }

    pub fn bye(self: *Self) Error!void {
        self.should_bye = true;
    }

    //;

    pub fn memStart(self: *Self) Error!void {
        try self.push(@ptrToInt(self.mem.ptr));
    }

    pub fn memSize(self: *Self) Error!void {
        try self.push(mem_size);
    }

    pub fn dictionaryStart(self: *Self) Error!void {
        try self.push(@ptrToInt(self.dictionary));
    }

    pub fn state(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.state));
    }

    pub fn latest(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.latest));
    }

    pub fn here(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.here));
    }

    pub fn base(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.base));
    }

    pub fn s0(self: *Self) Error!void {
        try self.push(@ptrToInt(self.stack));
    }

    pub fn sp(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.sp));
    }

    pub fn spFetch(self: *Self) Error!void {
        try self.push(self.sp);
    }

    pub fn spStore(self: *Self) Error!void {
        const val = try self.pop();
        self.sp = val;
    }

    pub fn rs0(self: *Self) Error!void {
        try self.push(@ptrToInt(self.rstack));
    }

    pub fn rsp(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.rsp));
    }

    pub fn fs0(self: *Self) Error!void {
        try self.push(@ptrToInt(self.fstack));
    }

    pub fn fsp(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.fsp));
    }

    //;

    pub fn dup(self: *Self) Error!void {
        const a = try self.pop();
        try self.push(a);
        try self.push(a);
    }

    pub fn dupMaybe(self: *Self) Error!void {
        const a = try self.pop();
        try self.push(a);
        if (a != forth_false) {
            try self.push(a);
        }
    }

    pub fn drop(self: *Self) Error!void {
        _ = try self.pop();
    }

    pub fn swap(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(a);
        try self.push(b);
    }

    pub fn over(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(b);
        try self.push(a);
        try self.push(b);
    }

    pub fn tuck(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(a);
        try self.push(b);
        try self.push(a);
    }

    pub fn nip(self: *Self) Error!void {
        const a = try self.pop();
        _ = try self.pop();
        try self.push(a);
    }

    // c b a > b a c
    pub fn rot(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        const c = try self.pop();
        try self.push(b);
        try self.push(a);
        try self.push(c);
    }

    // c b a > a c b
    pub fn nrot(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        const c = try self.pop();
        try self.push(a);
        try self.push(c);
        try self.push(b);
    }

    pub fn pick(self: *Self) Error!void {
        const at = try self.pop();
        const tos = self.sp;
        const offset = (1 + at) * @sizeOf(Cell);
        try self.push(try self.checkedRead(Cell, tos - offset));
    }

    pub fn swap2(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        const c = try self.pop();
        const d = try self.pop();
        try self.push(b);
        try self.push(a);
        try self.push(d);
        try self.push(c);
    }

    //;

    pub fn toR(self: *Self) Error!void {
        try self.rpush(try self.pop());
    }

    pub fn fromR(self: *Self) Error!void {
        try self.push(try self.rpop());
    }

    pub fn rFetch(self: *Self) Error!void {
        try self.push(try self.checkedRead(Cell, self.rsp - @sizeOf(Cell)));
    }

    //;

    pub fn define(self: *Self) Error!void {
        const len = try self.pop();
        const addr = try self.pop();
        if (len == 0) {
            try self.createWordHeader("", 0);
        } else if (len < word_max_len) {
            try self.createWordHeader(arrayAt(u8, addr, len), 0);
        } else {
            return error.WordTooLong;
        }
    }

    //     pub fn word(self: *Self) Error!void {
    //         const slc = try self.nextWord();
    //         try self.push(@ptrToInt(slc.ptr));
    //         try self.push(slc.len);
    //     }

    pub fn find(self: *Self) Error!void {
        const len = try self.pop();
        const addr = try self.pop();
        const ret = self.findWord(addr, len) catch |err| {
            switch (err) {
                error.WordNotFound => {
                    self.word_not_found = arrayAt(u8, addr, len);
                    try self.push(addr);
                    try self.push(forth_false);
                    return;
                },
                else => return err,
            }
        };

        try self.push(ret);
        try self.push(forth_true);
    }

    pub fn fetch(self: *Self) Error!void {
        const addr = try self.pop();
        try self.push(try self.checkedRead(Cell, addr));
    }

    pub fn store(self: *Self) Error!void {
        const addr = try self.pop();
        const val = try self.pop();
        try self.checkedWrite(Cell, addr, val);
    }

    pub fn comma(self: *Self) Error!void {
        try self.push(self.here);
        try self.store();
        self.here += @sizeOf(Cell);
    }

    pub fn fetchByte(self: *Self) Error!void {
        const addr = try self.pop();
        try self.push(try self.checkedRead(u8, addr));
    }

    pub fn storeByte(self: *Self) Error!void {
        const addr = try self.pop();
        const val = try self.pop();
        try self.checkedWrite(u8, addr, @intCast(u8, val & 0xff));
    }

    pub fn commaByte(self: *Self) Error!void {
        try self.push(self.here);
        try self.storeByte();
        self.here += 1;
    }

    pub fn fetchQuarter(self: *Self) Error!void {
        const addr = try self.pop();
        try self.push(try self.checkedRead(QuarterCell, addr));
    }

    pub fn storeQuarter(self: *Self) Error!void {
        const addr = try self.pop();
        const val = try self.pop();
        try self.checkedWrite(QuarterCell, addr, @intCast(QuarterCell, val & 0xffffffff));
    }

    pub fn commaQuarter(self: *Self) Error!void {
        try self.push(self.here);
        try self.storeQuarter();
        self.here += @sizeOf(QuarterCell);
    }

    pub fn fetchHalf(self: *Self) Error!void {
        const addr = try self.pop();
        try self.push(try self.checkedRead(HalfCell, addr));
    }

    pub fn storeHalf(self: *Self) Error!void {
        const addr = try self.pop();
        const val = try self.pop();
        try self.checkedWrite(HalfCell, addr, @intCast(HalfCell, val & 0xffffffff));
    }

    pub fn commaHalf(self: *Self) Error!void {
        try self.push(self.here);
        try self.storeHalf();
        self.here += @sizeOf(HalfCell);
    }

    pub fn tick(self: *Self) Error!void {
        try self.word();
        const word_len = try self.sidx(0);
        const word_addr = try self.sidx(1);
        _ = word_len;
        _ = word_addr;

        try self.find();
        if ((try self.pop()) == forth_false) {
            return error.WordNotFound;
        }
        try self.getCfa();
    }

    pub fn bracketTick(self: *Self) Error!void {
        try self.tick();
        try self.push(self.lit_address);
        try self.comma();
        try self.comma();
    }

    pub fn lBracket(self: *Self) Error!void {
        self.state = forth_false;
    }

    pub fn rBracket(self: *Self) Error!void {
        self.state = forth_true;
    }

    pub fn immediateFlag(self: *Self) Error!void {
        try self.push(word_immediate_flag);
    }

    pub fn hiddenFlag(self: *Self) Error!void {
        try self.push(word_hidden_flag);
    }

    pub fn makeImmediate(self: *Self) Error!void {
        const addr = try self.pop();
        wordHeaderFlags(addr).* ^= word_immediate_flag;
    }

    pub fn hide(self: *Self) Error!void {
        const addr = try self.pop();
        wordHeaderFlags(addr).* ^= word_hidden_flag;
    }

    pub fn getCfa(self: *Self) Error!void {
        const addr = try self.pop();
        try self.push(wordHeaderCodeFieldAddress(addr));
    }

    pub fn branch(self: *Self) Error!void {
        self.next +%= try self.checkedRead(Cell, self.next);
    }

    pub fn zbranch(self: *Self) Error!void {
        if ((try self.pop()) == forth_false) {
            self.next +%= try self.checkedRead(Cell, self.next);
        } else {
            self.next += @sizeOf(Cell);
        }
    }

    //;

    pub fn true_(self: *Self) Error!void {
        try self.push(forth_true);
    }

    pub fn false_(self: *Self) Error!void {
        try self.push(forth_false);
    }

    pub fn equal(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(if (a == b) forth_true else forth_false);
    }

    pub fn notEqual(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(if (a != b) forth_true else forth_false);
    }

    pub fn lt(self: *Self) Error!void {
        const a = @bitCast(SCell, try self.pop());
        const b = @bitCast(SCell, try self.pop());
        try self.push(if (b < a) forth_true else forth_false);
    }

    pub fn gt(self: *Self) Error!void {
        const a = @bitCast(SCell, try self.pop());
        const b = @bitCast(SCell, try self.pop());
        try self.push(if (b > a) forth_true else forth_false);
    }

    pub fn ult(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(if (b < a) forth_true else forth_false);
    }

    pub fn ugt(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(if (b > a) forth_true else forth_false);
    }

    pub fn and_(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(a & b);
    }

    pub fn or_(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(a | b);
    }

    pub fn xor(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(a ^ b);
    }

    pub fn invert(self: *Self) Error!void {
        const a = try self.pop();
        try self.push(~a);
    }

    pub fn lshift(self: *Self) Error!void {
        const ct = try self.pop();
        const a = try self.pop();
        try self.push(a << @intCast(u6, ct & 0x3f));
    }

    pub fn rshift(self: *Self) Error!void {
        const ct = try self.pop();
        const a = try self.pop();
        try self.push(a >> @intCast(u6, ct & 0x3f));
    }

    //;

    pub fn plus(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(b +% a);
    }

    pub fn minus(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(b -% a);
    }

    pub fn times(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        try self.push(b *% a);
    }

    pub fn divMod(self: *Self) Error!void {
        const a = try self.pop();
        const b = try self.pop();
        const q = b / a;
        const mod = b % a;
        try self.push(mod);
        try self.push(q);
    }

    pub fn cell(self: *Self) Error!void {
        try self.push(@sizeOf(Cell));
    }

    pub fn half(self: *Self) Error!void {
        try self.push(@sizeOf(HalfCell));
    }

    pub fn parseNumberForth(self: *Self) Error!void {
        const len = try self.pop();
        const addr = try self.pop();
        const num = parseNumber(arrayAt(u8, addr, len), self.base) catch |err| switch (err) {
            error.InvalidNumber => {
                try self.push(0);
                try self.push(forth_false);
                return;
            },
            else => return err,
        };
        try self.push(num);
        try self.push(forth_true);
    }

    pub fn plusStore(self: *Self) Error!void {
        const addr = try self.pop();
        const n = try self.pop();
        // TODO alignment error
        const ptr = @intToPtr(*Cell, addr);
        ptr.* +%= n;
    }

    //;

    pub fn showStack(self: *Self) Error!void {
        const len = (self.sp - @ptrToInt(self.stack)) / @sizeOf(Cell);
        std.debug.print("stack: len: {}\n", .{len});
        var i = len;
        var p = @ptrToInt(self.stack);
        while (p < self.sp) : (p += @sizeOf(Cell)) {
            i -= 1;
            std.debug.print("{}: 0x{x:.>16} {}\n", .{
                i,
                @intToPtr(*const Cell, p).*,
                @intToPtr(*const Cell, p).*,
            });
        }
    }

    //;

    pub fn litString(self: *Self) Error!void {
        const len = try self.checkedRead(Cell, self.next);
        self.next += @sizeOf(Cell);
        try self.push(self.next);
        try self.push(len);
        self.next += len;
        self.next = alignAddr(Cell, self.next);
    }

    pub fn type_(self: *Self) Error!void {
        const len = try self.pop();
        const addr = try self.pop();
        std.debug.print("{s}", .{arrayAt(u8, addr, len)});
    }

    //     pub fn key(self: *Self) Error!void {
    //         // TODO handle end of input
    //         const ch = try self.nextChar();
    //         try self.push(ch);
    //     }
    //
    //     pub fn keyAvailable(self: *Self) Error!void {
    //         // TODO
    //         //         if (self.currentInput()) |input| {
    //         //             try self.push(if (input.pos < input.str.len) forth_true else forth_false);
    //         //         } else {
    //         //             try self.push(forth_false);
    //         //         }
    //     }

    pub fn char(self: *Self) Error!void {
        try self.word();
        const len = try self.pop();
        const addr = try self.pop();
        try self.push(arrayAt(u8, addr, len)[0]);
    }

    pub fn emit(self: *Self) Error!void {
        std.debug.print("{c}", .{@intCast(u8, (try self.pop()) & 0xff)});
    }

    //;

    pub fn allocate(self: *Self) Error!void {
        const size = try self.pop();
        const real_size = alignAddr(Cell, size + @sizeOf(Cell));
        var mem = self.allocator.allocWithOptions(
            u8,
            real_size,
            @alignOf(Cell),
            null,
        ) catch |err| {
            switch (err) {
                error.OutOfMemory => {
                    try self.push(0);
                    try self.push(forth_false);
                    return;
                },
            }
        };
        const size_ptr = @ptrCast(*Cell, @alignCast(@alignOf(Cell), mem.ptr));
        size_ptr.* = real_size;
        const data_ptr = mem.ptr + @sizeOf(Cell);
        try self.push(@ptrToInt(data_ptr));
        try self.push(forth_true);
    }

    pub fn free_(self: *Self) Error!void {
        const addr = try self.pop();
        const data_ptr = @intToPtr([*]u8, addr);
        const mem_ptr = data_ptr - @sizeOf(Cell);
        const size_ptr = @ptrCast(*Cell, @alignCast(@alignOf(Cell), mem_ptr));
        var mem: []u8 = undefined;
        mem.ptr = mem_ptr;
        mem.len = size_ptr.*;
        self.allocator.free(mem);
    }

    pub fn resize(self: *Self) Error!void {
        // TODO
        const size = try self.pop();
        const addr = try self.pop();
        const data_ptr = @intToPtr([*]u8, addr);
        const mem_ptr = data_ptr - @sizeOf(Cell);
        const size_ptr = @ptrCast(*Cell, @alignCast(@alignOf(Cell), mem_ptr));
        var mem: []u8 = undefined;
        mem.ptr = mem_ptr;
        mem.len = size_ptr.*;
        try self.allocator.realloc(mem, size);
    }

    pub fn cmoveUp(self: *Self) Error!void {
        const len = try self.pop();
        const dest = @intToPtr([*]u8, try self.pop());
        const src = @intToPtr([*]u8, try self.pop());
        {
            @setRuntimeSafety(false);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                dest[i] = src[i];
            }
        }
    }

    pub fn cmoveDown(self: *Self) Error!void {
        const len = try self.pop();
        const dest = @intToPtr([*]u8, try self.pop());
        const src = @intToPtr([*]u8, try self.pop());
        {
            @setRuntimeSafety(false);
            var i: usize = len;
            while (i > 0) : (i -= 1) {
                dest[i - 1] = src[i - 1];
            }
        }
    }

    pub fn memEql(self: *Self) Error!void {
        const ct = try self.pop();
        const addr_a = try self.pop();
        const addr_b = try self.pop();
        if (addr_a == addr_b) {
            try self.push(forth_true);
            return;
        }
        var i: usize = 0;
        while (i < ct) : (i += 1) {
            if ((try self.checkedRead(u8, addr_a)) !=
                (try self.checkedRead(u8, addr_b)))
            {
                try self.push(forth_false);
                return;
            }
        }
        try self.push(forth_true);
    }

    // ===

    pub fn fPrint(self: *Self) Error!void {
        const float = try self.fpop();
        std.debug.print("{d} ", .{float});
    }

    pub fn fSize(self: *Self) Error!void {
        try self.push(@sizeOf(Float));
    }

    pub fn fPlus(self: *Self) Error!void {
        const a = try self.fpop();
        const b = try self.fpop();
        try self.fpush(b + a);
    }

    pub fn fMinus(self: *Self) Error!void {
        const a = try self.fpop();
        const b = try self.fpop();
        try self.fpush(b - a);
    }

    pub fn fTimes(self: *Self) Error!void {
        const a = try self.fpop();
        const b = try self.fpop();
        try self.fpush(b * a);
    }

    pub fn fDivide(self: *Self) Error!void {
        const a = try self.fpop();
        const b = try self.fpop();
        try self.fpush(b / a);
    }

    pub fn fSin(self: *Self) Error!void {
        const val = try self.fpop();
        try self.fpush(std.math.sin(val));
    }

    pub fn pi(self: *Self) Error!void {
        try self.fpush(std.math.pi);
    }

    pub fn tau(self: *Self) Error!void {
        try self.fpush(std.math.tau);
    }

    pub fn fFetch(self: *Self) Error!void {
        const addr = try self.pop();
        try self.fpush(try self.checkedRead(Float, addr));
    }

    pub fn fStore(self: *Self) Error!void {
        const addr = try self.pop();
        const val = try self.fpop();
        try self.checkedWrite(Float, addr, val);
    }

    pub fn fComma(self: *Self) Error!void {
        try self.push(self.here);
        try self.fStore();
        self.here += @sizeOf(Float);
    }

    pub fn fPlusStore(self: *Self) Error!void {
        const addr = try self.pop();
        const n = try self.fpop();
        // TODO alignment error
        const ptr = @intToPtr(*Float, addr);
        ptr.* += n;
    }

    pub fn fParse(self: *Self) Error!void {
        const len = try self.pop();
        const addr = try self.pop();
        const str = arrayAt(u8, addr, len);
        const fl = parseFloat(str) catch |err| switch (err) {
            error.InvalidFloat => {
                try self.fpush(0);
                try self.push(forth_false);
                return;
            },
            else => return err,
        };
        try self.fpush(fl);
        try self.push(forth_true);
    }

    pub fn fDrop(self: *Self) Error!void {
        _ = try self.fpop();
    }

    pub fn fDup(self: *Self) Error!void {
        const f = try self.fpop();
        try self.fpush(f);
        try self.fpush(f);
    }

    pub fn fSwap(self: *Self) Error!void {
        const a = try self.fpop();
        const b = try self.fpop();
        try self.fpush(a);
        try self.fpush(b);
    }

    pub fn fToS(self: *Self) Error!void {
        const f = try self.fpop();
        const s = @floatToInt(Cell, std.math.trunc(f));
        try self.push(s);
    }

    pub fn sToF(self: *Self) Error!void {
        const s = try self.pop();
        try self.fpush(@intToFloat(Float, s));
    }

    // ===

    pub fn fileRO(self: *Self) Error!void {
        try self.push(file_read_flag);
    }

    pub fn fileWO(self: *Self) Error!void {
        try self.push(file_write_flag);
    }

    pub fn fileRW(self: *Self) Error!void {
        try self.push(file_write_flag | file_read_flag);
    }

    pub fn fileOpen(self: *Self) Error!void {
        const permissions = try self.pop();
        const len = try self.pop();
        const addr = try self.pop();

        var flags = std.fs.File.OpenFlags{
            .read = (permissions & file_read_flag) != 0,
            .write = (permissions & file_write_flag) != 0,
        };

        var f = std.fs.cwd().openFile(arrayAt(u8, addr, len), flags) catch {
            try self.push(0);
            try self.push(forth_false);
            return;
        };
        errdefer f.close();

        var file = try self.allocator.create(std.fs.File);
        file.* = f;

        try self.push(@ptrToInt(file));
        try self.push(forth_true);
    }

    pub fn fileClose(self: *Self) Error!void {
        const f = try self.pop();
        var ptr = @intToPtr(*std.fs.File, f);
        ptr.close();
        self.allocator.destroy(ptr);
    }

    pub fn fileSize(self: *Self) Error!void {
        const f = try self.pop();
        var ptr = @intToPtr(*std.fs.File, f);
        try self.push(ptr.getEndPos() catch unreachable);
    }

    pub fn fileRead(self: *Self) Error!void {
        const f = try self.pop();
        const n = try self.pop();
        const addr = try self.pop();

        var ptr = @intToPtr(*std.fs.File, f);
        var buf = arrayAt(u8, addr, n);
        // TODO handle read errors
        const ct = ptr.read(buf) catch unreachable;

        try self.push(ct);
    }

    // ( buffer n file -- read-ct delimiter-found? )
    pub fn fileReadLine(self: *Self) Error!void {
        const f = try self.pop();
        const n = try self.pop();
        const addr = try self.pop();

        var ptr = @intToPtr(*std.fs.File, f);
        var reader = ptr.reader();

        var buf = arrayAt(u8, addr, n);
        // TODO handle read errors
        const slc = reader.readUntilDelimiterOrEof(buf, '\n') catch unreachable;
        if (slc) |s| {
            try self.push(s.len);
            try self.push(forth_true);
        } else {
            try self.push(0);
            try self.push(forth_false);
        }
    }

    // ===

    pub fn sourceUserInput(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.source_user_input));
    }

    pub fn sourcePtr(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.source_ptr));
    }

    pub fn sourceLen(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.source_len));
    }

    pub fn sourceIn(self: *Self) Error!void {
        try self.push(@ptrToInt(&self.source_in));
    }

    fn refillReader(self: *Self, reader: anytype) Error!void {
        var line = reader.readUntilDelimiterOrEof(self.input_buffer[0..(input_buffer_size - 1)], '\n') catch |err| {
            switch (err) {
                // TODO
                error.StreamTooLong => unreachable,
                // TODO
                else => unreachable,
            }
        };
        if (line) |s| {
            self.input_buffer[s.len] = '\n';
            self.source_ptr = @ptrToInt(self.input_buffer);
            self.source_len = s.len + 1;
            self.source_in = 0;
            try self.push(forth_true);
        } else {
            try self.push(forth_false);
        }
    }

    pub fn refill(self: *Self) Error!void {
        if (self.source_user_input == forth_true) {
            std.debug.print("> ", .{});
            try self.refillReader(std.io.getStdIn().reader());
        } else {
            try self.push(forth_false);
        }
    }

    // ===

    pub fn panic_(self: *Self) Error!void {
        _ = self;
        return error.Panic;
    }
};
