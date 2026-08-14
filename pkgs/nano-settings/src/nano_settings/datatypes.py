"""The shapes that arrive as JSON, spelled out once.

Three files cross into this application from outside it: schema.json, written
by schema.nix out of modules/options.nix; catalog.json, written by hand; and
/etc/nixos/nanoDesktop-settings.json, whose shape is whatever the module
system will take. Python sees all three as nested dicts of anything, which is
exactly the type the rest of this package should never have to reason about.

So each one is narrowed here, at the boundary, into a TypedDict the rest of
the code can index without asking whether the key is there. The narrowing is
not decorative: a settings file can be edited by hand, a catalogue can gain
an entry with a typo in it, and a schema built from a checkout mid-edit can
be missing an option the presentation layer still lists. Deciding what each
of those means once, here, is what keeps `.get(..., default)` out of the two
hundred lines that draw the window.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import TypedDict

# Everything json.load can return. A `type` alias rather than an assignment,
# so the reference to itself resolves lazily and the recursion needs no
# quoting.
type JSONValue = bool | int | float | str | list[JSONValue] | dict[str, JSONValue] | None
type JSONObject = dict[str, JSONValue]

# What one nanoDesktop option can hold. The same set as JSONValue, because
# the settings file is the only place these values are ever written, and
# named separately because it reads as the domain rather than the encoding.
type SettingValue = JSONValue

# The two callback shapes the pages hand back to the window: "something
# changed" and "root has started or stopped working".
type OnChange = Callable[[], None]
type OnBusy = Callable[[bool], None]


class SchemaEntry(TypedDict):
    """One option, as schema.nix's `render` writes it.

    Total, and kept that way by narrow_schema_entry below: the app leans on
    `type` to choose a widget and on `enum` to fill it, and a schema entry
    missing either is not something to paper over with a default at the point
    of use — it is a schema that was not built from options.nix.
    """

    type: str
    # For type == "list": what the list holds. None for everything else.
    elemType: str | None
    # For type == "enum": the members, in the order options.nix declares
    # them, which is the order they are offered in.
    enum: list[str] | None
    default: JSONValue
    # The full argument from options.nix, shown behind the row's help button.
    description: str


class CatalogItem(TypedDict):
    """One offering on the Software page, as catalog.json writes it.

    Only `attr` and `name` are given for every entry in that file; the rest
    are filled in by narrow_catalog_item, so the page can render a row
    without a conditional per field.
    """

    attr: str
    name: str
    category: str
    summary: str
    unfree: bool


# Where an entry with no category of its own is filed.
OTHER_CATEGORY = "Other"


class MalformedError(ValueError):
    """A file that is JSON, but not the JSON this application expects."""


def narrow_schema_entry(where: str, raw: JSONValue) -> SchemaEntry:
    """One node of schema.json as a SchemaEntry, or raise saying which one."""
    if not isinstance(raw, dict):
        raise MalformedError(f"{where} is not an object.")

    kind = raw.get("type")
    if not isinstance(kind, str):
        raise MalformedError(f"{where} has no option type.")

    elem = raw.get("elemType")
    if elem is not None and not isinstance(elem, str):
        raise MalformedError(f"{where} has a list element type that is not a name.")

    members = raw.get("enum")
    if members is None:
        values = None
    elif isinstance(members, list) and all(isinstance(item, str) for item in members):
        # The isinstance-over-all above is what makes this cast-free; mypy
        # cannot see through all(), so the members are rebuilt rather than
        # reused.
        values = [item for item in members if isinstance(item, str)]
    else:
        raise MalformedError(f"{where} has enum values that are not names.")

    description = raw.get("description")
    return SchemaEntry(
        type=kind,
        elemType=elem,
        enum=values,
        default=raw.get("default"),
        description=description if isinstance(description, str) else "",
    )


def narrow_catalog_item(raw: JSONValue) -> CatalogItem | None:
    """One entry of catalog.json, or None if it is not one.

    None rather than an exception: the catalogue is a convenience, and one
    malformed line in it is not worth an application that will not start.
    The Software page drops what it cannot read and shows the rest.
    """
    if not isinstance(raw, dict):
        return None

    attr = raw.get("attr")
    name = raw.get("name")
    if not isinstance(attr, str) or not attr or not isinstance(name, str) or not name:
        return None

    category = raw.get("category")
    summary = raw.get("summary")
    return CatalogItem(
        attr=attr,
        name=name,
        category=category if isinstance(category, str) and category else OTHER_CATEGORY,
        summary=summary if isinstance(summary, str) else "",
        unfree=raw.get("unfree") is True,
    )
