/*
 * The parsers built into the YasOS ctags.
 *
 * Universal-ctags includes EXTERNAL_PARSER_LIST_FILE right after its own
 * main/parsers_p.h (see main/parse_p.h), so redefining PARSER_LIST here
 * replaces the ~150 built-in parsers without patching the submodule; ctags'
 * internal CTags/Fallback/SelfTest entries stay first in the table. A parser
 * left out here is never referenced, so its object stays out of the link.
 * build_rootfs.sh also passes -UHAVE_PACKCC, which drops the five PEG parsers
 * (Kotlin, Thrift, Elm, TOML, Varlink) the same way.
 *
 * Adding a language: name its parserDefinitionFunc (main/parsers_p.h) and
 * everything it declares a DEPTYPE_FOREIGNER / base-parser dependency on,
 * since those are looked up by name at run time. C and Asm both reach into
 * LdScript; Make and C use CPreProcessor.
 *
 * ZigParser is not upstream: build_rootfs.sh generates it from zig.ctags in
 * this directory with the submodule's misc/optlib2c and adds it to libctags.a.
 */
#undef PARSER_LIST
#define PARSER_LIST \
	CParser, \
	CPreProParser, \
	LdScriptParser, \
	AsmParser, \
	MakefileParser, \
	ShParser, \
	KconfigParser, \
	ZigParser
