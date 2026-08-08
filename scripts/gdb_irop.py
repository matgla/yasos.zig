import gdb


def _to_uint32(value: int) -> int:
    return int(value) & 0xFFFFFFFF


def _decode_vr(raw_vr: int) -> dict:
    raw = _to_uint32(raw_vr)
    return {
        "raw": raw,
        "tag": (raw >> 18) & 0x7,
        "is_lval": (raw >> 21) & 0x1,
        "is_llocal": (raw >> 22) & 0x1,
        "is_local": (raw >> 23) & 0x1,
        "is_const": (raw >> 24) & 0x1,
        "btype": (raw >> 25) & 0x7,
        "vreg_type": (raw >> 28) & 0xF,
        "position": raw & 0x3FFFF,
    }


def _print_compare(prefix: str, op_val: gdb.Value) -> None:
    raw_vr = int(op_val["vr"])
    decoded = _decode_vr(raw_vr)

    bf_tag = int(op_val["tag"])
    bf_lval = int(op_val["is_lval"])
    bf_llocal = int(op_val["is_llocal"])
    bf_local = int(op_val["is_local"])
    bf_const = int(op_val["is_const"])
    bf_btype = int(op_val["btype"])
    bf_vtype = int(op_val["vreg_type"])
    bf_pos = int(op_val["position"])

    gdb.write(f"{prefix}raw.vr=0x{decoded['raw']:08x}\n")
    gdb.write(
        f"{prefix}raw: tag={decoded['tag']} lval={decoded['is_lval']} llocal={decoded['is_llocal']} "
        f"local={decoded['is_local']} const={decoded['is_const']} btype={decoded['btype']} "
        f"vtype={decoded['vreg_type']} pos={decoded['position']}\n"
    )
    gdb.write(
        f"{prefix} bf: tag={bf_tag} lval={bf_lval} llocal={bf_llocal} "
        f"local={bf_local} const={bf_const} btype={bf_btype} vtype={bf_vtype} pos={bf_pos}\n"
    )


def _eval_as_iroperand(expr: str) -> gdb.Value:
    raw_value = gdb.parse_and_eval(expr)
    raw_type = raw_value.type.strip_typedefs()
    value = raw_value.dereference() if raw_type.code == gdb.TYPE_CODE_PTR else raw_value

    try:
        value["tag"]
        value["vr"]
        return value
    except gdb.error:
        pass

    try:
        ir_expr = gdb.parse_and_eval("ir")
        if ir_expr.type.strip_typedefs().code != gdb.TYPE_CODE_PTR:
            raise gdb.GdbError("'ir' is not a pointer in current frame")
    except gdb.error as exc:
        raise gdb.GdbError("Cannot find usable 'ir' in current frame for SValue conversion") from exc

    # First, if this clearly looks like SValue, convert accordingly.
    try:
        value["r"]
        value["vr"]
        if raw_type.code == gdb.TYPE_CODE_PTR:
            return gdb.parse_and_eval(f"(IROperand)svalue_to_iroperand(ir, {expr})")
        return gdb.parse_and_eval(f"(IROperand)svalue_to_iroperand(ir, &({expr}))")
    except gdb.error:
        pass

    # Fallback for opaque/partial debug types: try both pointer/value forms.
    if raw_type.code == gdb.TYPE_CODE_PTR:
        try:
            return gdb.parse_and_eval(f"(IROperand)svalue_to_iroperand(ir, {expr})")
        except gdb.error:
            pass
    else:
        try:
            return gdb.parse_and_eval(f"(IROperand)svalue_to_iroperand(ir, &({expr}))")
        except gdb.error:
            pass

    raise gdb.GdbError(
        "Expression is neither IROperand nor convertible SValue. "
        "Use IROperand, or SValue/SValue* with in-scope 'ir'."
    )


class IropRawDecode(gdb.Command):
    """irop_raw_decode_py <IROperand_expr|SValue_expr>\nCompare raw vr bit decode vs C bitfield members.\nIf SValue/SValue* is passed, converts via svalue_to_iroperand(ir,...)."""

    def __init__(self):
        super().__init__("irop_raw_decode_py", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        expr = arg.strip()
        if not expr:
            raise gdb.GdbError("Usage: irop_raw_decode_py <IROperand_expr|SValue_expr>")

        op = _eval_as_iroperand(expr)

        _print_compare("", op)


class IropPoolCheck(gdb.Command):
    """irop_pool_check_py <ir_expr> <idx_expr>\nDump pool entry bytes and compare raw/bitfield decode."""

    def __init__(self):
        super().__init__("irop_pool_check_py", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        if len(argv) != 2:
            raise gdb.GdbError("Usage: irop_pool_check_py <ir_expr> <idx_expr>")

        ir = gdb.parse_and_eval(argv[0])
        if ir.type.strip_typedefs().code != gdb.TYPE_CODE_PTR:
            raise gdb.GdbError("<ir_expr> must evaluate to pointer (e.g. ir)")

        idx = int(gdb.parse_and_eval(argv[1]))
        pool = ir["iroperand_pool"]
        entry_ptr = (pool + idx)
        entry = entry_ptr.dereference()

        addr = int(entry_ptr)
        gdb.write(f"pool[{idx}] @ 0x{addr:x}\n")
        gdb.execute(f"x/10xb 0x{addr:x}", from_tty=False)

        _print_compare("", entry)

        imm32 = int(entry["u"]["imm32"])
        pool_idx = _to_uint32(int(entry["u"]["pool_idx"]))
        gdb.write(f"u.imm32={imm32} u.pool_idx={pool_idx}\n")


IropRawDecode()
IropPoolCheck()

gdb.write("Loaded gdb_irop.py commands: irop_raw_decode_py, irop_pool_check_py\n")
