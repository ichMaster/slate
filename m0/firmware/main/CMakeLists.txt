idf_component_register(
    SRCS
        "main.c"
        "panel_probe.c"
        "xml_poc.c"
    INCLUDE_DIRS "."
    # The M0 page travels in the binary at v0.1: HTTP arrives with SLATE-006, so
    # embedding lets the XML PoC measure parsing alone, with no network in the
    # numbers. It is the same file the server serves, not a copy.
    EMBED_TXTFILES "../../apps/m0.xml"
)
