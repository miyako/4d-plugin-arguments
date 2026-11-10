// Only engine-boundary behavior is modeled; all PA_* calls use the bundled SDK.
#include "4DPlugin-arguments.h"
#include "PrivateTypes.h"
#include "EntryPoints.h"
#include "ARRAY_TEXT.h"
#include "C_TEXT.h"
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <stdexcept>

static void require(bool condition, const char *message)
{
    if (!condition) throw std::runtime_error(message);
}

static bool allocatedEmpty = true;
static bool failGet = false;
static size_t clearCalls = 0;
static std::map<PA_Unichar *, size_t> strings;
static std::map<PA_Handle, size_t> handles;
static std::set<PA_Picture> pictures;

struct Node {
    int refs = 1;
    std::map<CUTF16String, PA_Variable> properties;
    std::vector<PA_Variable> elements;
};
static std::set<Node *> nodes;

static CUTF16String text(const PA_Unistring &value)
{
    PA_Unichar *buffer = value.fString;
    if (!buffer) {
        require(value.fLength == 0, "null string with nonzero length");
        return {};
    }
    require(strings.count(buffer), "read of unowned/dangling string");
    require(strings.at(buffer) == size_t(value.fLength) + 1,
            "string allocation/UTF-16 length mismatch");
    require(value.fString[value.fLength] == 0, "missing UTF-16 terminator");
    return CUTF16String(value.fString, value.fLength);
}

static PA_Unistring makeString(const PA_Unichar *value)
{
    PA_Unistring result = {};
    size_t length = 0;
    if (value) while (value[length]) ++length;
    if (!length && !allocatedEmpty) return result;
    result.fString = static_cast<PA_Unichar *>(calloc(length + 1, sizeof(PA_Unichar)));
    require(result.fString != nullptr, "test allocation failed");
    result.fLength = PA_long32(length);
    if (length) memcpy(result.fString, value, length * sizeof(PA_Unichar));
    PA_Unichar *buffer = result.fString;
    strings.emplace(buffer, length + 1);
    return result;
}

static void freeString(PA_Unistring value)
{
    PA_Unichar *buffer = value.fString;
    if (buffer) {
        text(value);
        require(strings.erase(buffer) == 1, "double string disposal");
        free(buffer);
    }
}

static Node *node(void *value)
{
    auto result = static_cast<Node *>(value);
    require(nodes.count(result), "dangling object/collection reference");
    return result;
}

static Node *newNode()
{
    auto result = new Node;
    nodes.insert(result);
    return result;
}

static void clear(PA_Variable &value);

static void release(void *value)
{
    if (!value) return;
    Node *owner = node(value);
    if (--owner->refs) return;
    for (auto &entry : owner->properties) clear(entry.second);
    for (auto &entry : owner->elements) clear(entry);
    nodes.erase(owner);
    delete owner;
}

static PA_Variable copy(PA_Variable value)
{
    if (value.fType == eVK_Unistring) {
        auto buffer = text(value.uValue.fString);
        value.uValue.fString = makeString(buffer.c_str());
    } else if (value.fType == eVK_Object || value.fType == eVK_Collection) {
        if (value.uValue.fObject) ++node(value.uValue.fObject)->refs;
    } else if (value.fType == eVK_Picture && value.uValue.fPicture) {
        PA_Picture original = value.uValue.fPicture;
        require(pictures.count(original), "dangling picture");
        auto picture = malloc(1);
        pictures.insert(picture);
        value.uValue.fPicture = picture;
    }
    return value;
}

static void clear(PA_Variable &value)
{
    switch (value.fType) {
        case eVK_Unistring: freeString(value.uValue.fString); break;
        case eVK_Object: case eVK_Collection: release(value.uValue.fObject); break;
        case eVK_Picture: {
            PA_Picture picture = value.uValue.fPicture;
            if (picture) {
                require(pictures.erase(picture) == 1, "double picture disposal");
                free(picture);
            }
            break;
        }
        case eVK_ArrayUnicode: {
            PA_Handle handle = value.uValue.fArray.fData;
            require(handles.count(handle), "unowned array handle");
            auto entries = reinterpret_cast<PA_Unistring *>(*handle);
            for (int i = 0; i <= value.uValue.fArray.fNbElements; ++i)
                freeString(entries[i]);
            handles.erase(handle);
            free(*handle);
            free(handle);
            break;
        }
        default: break;
    }
    value = {};
    value.fType = eVK_Undefined;
}

static void engine(short selector, EngineBlock *eb)
{
    eb->fError = eER_NoErr;
    switch (selector) {
        case EX_CREATE_UNISTRING:
            eb->fUniString1 = makeString(reinterpret_cast<PA_Unichar *>(eb->fHandle));
            break;
        case EX_DISPOSE_UNISTRING: freeString(eb->fUniString1); break;
        case EX_SET_UNISTRING: {
            // Content setter: input is a UTF-16 buffer, not a transferred descriptor.
            auto result = makeString(reinterpret_cast<PA_Unichar *>(eb->fHandle));
            freeString(eb->fUniString1);
            eb->fUniString1 = result;
            break;
        }
        case EX_VARIABLE_TO_STRING: {
            auto value = reinterpret_cast<PA_Variable *>(eb->fHandle);
            require(value->fType == eVK_Unistring, "non-string getter input");
            text(value->uValue.fString);
            eb->fUniString1 = value->uValue.fString;
            break;
        }
        case EX_CLEAR_VARIABLE:
            ++clearCalls;
            clear(*static_cast<PA_Variable *>(eb->fPtr1));
            break;
        case EX_CREATE_PICTURE: {
            PA_Picture picture = malloc(1);
            eb->fPicture = picture;
            pictures.insert(picture);
            break;
        }
        case EX_DISPOSE_PICTURE: {
            PA_Picture picture = eb->fPicture;
            require(pictures.erase(picture) == 1, "unowned picture disposal");
            free(picture);
            break;
        }
        case EX_HANDLE_MANAGER: {
            PA_Handle handle = eb->fParam1 == 1 ? nullptr : eb->fHandle;
            switch (eb->fParam1) {
                case 1:
                    handle = static_cast<PA_Handle>(malloc(sizeof(char *)));
                    *handle = static_cast<char *>(calloc(size_t(eb->fParam2) + 1, 1));
                    handles.emplace(handle, size_t(eb->fParam2));
                    eb->fHandle = handle;
                    break;
                case 2:
                    require(handles.erase(handle) == 1, "unowned handle disposal");
                    free(*handle);
                    free(handle);
                    break;
                case 3:
                    require(handles.count(handle), "unowned handle resize");
                    *handle = static_cast<char *>(realloc(*handle, size_t(eb->fParam2) + 1));
                    handles[handle] = eb->fParam2;
                    break;
                case 4:
                    require(handles.count(handle), "unowned handle size");
                    eb->fParam2 = handles.at(handle);
                    break;
                case 5:
                    require(handles.count(handle), "unowned handle lock");
                    eb->fParam3 = reinterpret_cast<sLONG_PTR>(*handle);
                    break;
                case 6: case 7: case 8: break;
                default: throw std::runtime_error("unexpected handle operation");
            }
            break;
        }
        case EX_SET_OBJ_VALUE: {
            auto owner = node(eb->fPtr1);
            auto input = static_cast<PA_Variable *>(eb->fPtr2);
            if (eb->fShort == eVK_Collection) {
                require(eb->fLongint >= 0, "negative collection index");
                owner->elements.resize(size_t(eb->fLongint) + 1);
                clear(owner->elements[eb->fLongint]);
                owner->elements[eb->fLongint] = copy(*input);
            } else {
                auto key = text(eb->fUniString1);
                clear(owner->properties[key]);
                owner->properties[key] = copy(*input);
            }
            break;
        }
        case EX_GET_OBJ_VALUE: {
            auto owner = node(eb->fPtr1);
            auto output = static_cast<PA_Variable *>(eb->fPtr2);
            if (failGet) {
                // Failed output is deliberately not a valid, clearable PA_Variable.
                memset(output, 0xa5, sizeof(*output));
                output->fType = eVK_Unistring;
                output->uValue.fString.fString = reinterpret_cast<PA_Unichar *>(1);
                eb->fError = eER_IncompatibleTypes;
            } else if (eb->fShort == eVK_Collection && eb->fLongint == -1) {
                PA_SetLongintVariable(output, PA_long32(owner->elements.size()));
            } else if (eb->fShort == eVK_Collection) {
                *output = copy(owner->elements.at(eb->fLongint));
            } else {
                *output = copy(owner->properties.at(text(eb->fUniString1)));
            }
            break;
        }
        case EX_EXECUTE_COMMAND_BY_ID: {
            auto output = static_cast<PA_Variable *>(eb->fPtr2);
            auto args = static_cast<PA_Variable **>(eb->fPtr1);
            switch (eb->fParam1) {
                case 1472: PA_SetCollectionVariable(output, newNode()); break;
                case 1231:
                    PA_SetBooleanVariable(output,
                        node(args[0]->uValue.fObject)->properties.count(text(args[1]->uValue.fString)));
                    break;
                case 1225: {
                    auto result = newNode();
                    for (auto &entry : node(args[0]->uValue.fObject)->properties)
                        result->properties[entry.first] = copy(entry.second);
                    PA_SetObjectVariable(output, result);
                    break;
                }
                case 1217: {
                    auto result = makeString(reinterpret_cast<const PA_Unichar *>(u"{}"));
                    PA_SetStringVariable(output, &result);
                    break;
                }
                default: throw std::runtime_error("unexpected command");
            }
            break;
        }
        default: throw std::runtime_error("unexpected engine selector");
    }
}

static void balanced(const char *message)
{
    if (!strings.empty() || !handles.empty() || !nodes.empty() || !pictures.empty()) {
        std::cerr << "live strings=" << strings.size() << " handles=" << handles.size()
                  << " nodes=" << nodes.size() << " pictures=" << pictures.size() << "\n";
        throw std::runtime_error(message);
    }
}

static PA_Unichar *utf16(const char16_t *value)
{
    static_assert(sizeof(PA_Unichar) == sizeof(char16_t), "UTF-16 unit width");
    return reinterpret_cast<PA_Unichar *>(const_cast<char16_t *>(value));
}

static void expect(PA_Unistring value, const char16_t *expected)
{
    require(text(value) == CUTF16String(utf16(expected)), "incorrect exact UTF-16 content");
}

static void command(int argc, char **argv)
{
    for (int repeat = 0; repeat != 4; ++repeat) {
        PA_CollectionRef result = nullptr;
        PluginBlock params = {};
        params.fResult = &result;
        PluginMain(1, &params);
        require(PA_GetCollectionLength(result) == argc, "argument collection length");
        for (int i = 0; i < argc; ++i) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            std::vector<PA_Unichar> expected([arg length] + 1);
            [arg getCharacters:expected.data() range:NSMakeRange(0, [arg length])];
            PA_Variable value = PA_GetCollectionElement(result, i);
            require(text(PA_GetStringVariable(value)) == CUTF16String(expected.data()),
                    "argument text corrupted after temporary owner cleanup");
            PA_ClearVariable(&value);
        }
        PA_DisposeCollection(result);
        balanced("command leaked overwritten empty strings");
    }
}

static void setters()
{
    auto owner = newNode();
    struct Fixture {
        const char *u8;
        const wchar_t *wide;
        const char16_t *u16;
    };
    for (auto fixture : {
            Fixture{"ASCII", L"ASCII", u"ASCII"},
            Fixture{"\xe6\x97\xa5\xe6\x9c\xac", L"\u65e5\u672c", u"\u65e5\u672c"},
            Fixture{"\xf0\x9f\x98\x80", L"\U0001f600", u"\U0001f600"},
            Fixture{"", L"", u""}}) {
        CUTF16String value(utf16(fixture.u16));
        ob_set_s(owner, "narrow", fixture.u8);
        ob_set_s(owner, L"wide", fixture.u8);
        ob_set_a(owner, L"wide-value", fixture.wide);
        ob_set_a(owner, L"native-value", &value);
        for (auto &entry : owner->properties)
            expect(entry.second.uValue.fString, fixture.u16);
    }
    auto picture = PA_CreatePicture(nullptr, 0);
    ob_set_p(owner, L"picture", picture);
    PA_DisposeObject(owner);
    balanced("setter leaked overwritten empty string/picture");
}

static PA_Unistring keyString()
{
    return PA_CreateUnistring(utf16(u"key"));
}

static void put(Node *owner, PA_Variable value)
{
    auto key = keyString();
    PA_SetObjectProperty(owner, &key, value);
    PA_ClearVariable(&value);
    PA_DisposeUnistring(&key);
}

static void getters()
{
    const char *expected = "A\xe6\x97\xa5\xf0\x9f\x98\x80";
    for (int getter = 0; getter != 5; ++getter) {
        auto owner = newNode();
        PA_Variable value = PA_CreateVariable(eVK_Undefined);
        auto str = PA_CreateUnistring(utf16(u"A\u65e5\U0001f600"));
        PA_SetStringVariable(&value, &str);
        put(owner, value);
        CUTF8String output;
        size_t before = clearCalls;
        if (getter == 0) {
            require(ob_get_a(owner, L"key", &output), "existing property missing");
            require(output == CUTF8String(reinterpret_cast<const uint8_t *>(expected)),
                    "wrong exact UTF-8 output");
        }
        if (getter == 1) require(!ob_get_b(owner, L"key"), "boolean mismatch behavior");
        if (getter == 2) require(ob_get_n(owner, L"key") == 0, "real mismatch behavior");
        if (getter == 3) require(ob_get_c(owner, L"key") == nullptr, "collection mismatch behavior");
        if (getter == 4) require(ob_get_o(owner, L"key") == nullptr, "object mismatch behavior");
        require(clearCalls == before + 1, "successful scalar/mismatch getter must clear result");
        PA_DisposeObject(owner);
        balanced("getter leaked successful owning string/mismatched result");
    }
    auto owner = newNode();
    ob_set_b(owner, L"key", true);
    size_t before = clearCalls;
    require(ob_get_b(owner, L"key"), "boolean changed");
    require(clearCalls == before + 1, "boolean owning result not cleared");
    ob_set_n(owner, L"key", 3.25);
    before = clearCalls;
    require(ob_get_n(owner, L"key") == 3.25, "real changed");
    require(clearCalls == before + 1, "real owning result not cleared");
    ob_set_s(owner, "key", "");
    CUTF8String empty(reinterpret_cast<const uint8_t *>("old"));
    require(ob_get_a(owner, L"key", &empty) && empty.empty(), "empty getter content");
    for (int kind : {eVK_Object, eVK_Collection}) {
        PA_Variable reference = PA_CreateVariable(eVK_Undefined);
        if (kind == eVK_Object) PA_SetObjectVariable(&reference, newNode());
        else PA_SetCollectionVariable(&reference, newNode());
        put(owner, reference);
        for (int getter = 0; getter != 5; ++getter) {
            if ((kind == eVK_Object && getter == 4) || (kind == eVK_Collection && getter == 3))
                continue;
            before = clearCalls;
            if (getter == 0) ob_get_a(owner, L"key", &empty);
            if (getter == 1) ob_get_b(owner, L"key");
            if (getter == 2) ob_get_n(owner, L"key");
            if (getter == 3) ob_get_c(owner, L"key");
            if (getter == 4) ob_get_o(owner, L"key");
            require(clearCalls == before + 1, "mismatched reference result not cleared");
        }
    }
    PA_DisposeObject(owner);
    balanced("scalar getter balance");
}

static void failures()
{
    for (int getter = 0; getter != 5; ++getter) {
        auto owner = newNode();
        ob_set_b(owner, L"key", true);
        failGet = true;
        bool reported = false;
        try {
            CUTF8String output;
            if (getter == 0) ob_get_a(owner, L"key", &output);
            if (getter == 1) ob_get_b(owner, L"key");
            if (getter == 2) ob_get_n(owner, L"key");
            if (getter == 3) ob_get_c(owner, L"key");
            if (getter == 4) ob_get_o(owner, L"key");
        } catch (const std::runtime_error &error) {
            reported = std::string(error.what()).find("PA_GetObjectProperty failed") != std::string::npos;
        }
        failGet = false;
        PA_DisposeObject(owner);
        require(reported, "failed getter not explicitly reported before inspecting output");
        balanced("failed getter cleanup");
    }
}

static void handoffs()
{
    for (int kind : {eVK_Object, eVK_Collection}) {
        auto owner = newNode();
        auto child = newNode();
        PA_Variable value = PA_CreateVariable(eVK_Undefined);
        if (kind == eVK_Object) {
            PA_SetObjectVariable(&value, child);
            ob_set_b(child, L"alive", true);
        } else {
            PA_SetCollectionVariable(&value, child);
            PA_Variable element = PA_CreateVariable(eVK_Boolean);
            PA_SetBooleanVariable(&element, true);
            PA_SetCollectionElement(child, 0, element);
        }
        put(owner, value);
        auto result = kind == eVK_Object ? ob_get_o(owner, L"key") : ob_get_c(owner, L"key");
        PA_DisposeObject(owner);
        require(node(result)->refs == 1, "getter must hand off exactly one owned reference");
        if (kind == eVK_Object) {
            require(ob_get_b(result, L"alive"), "object handoff invalidated");
            PA_DisposeObject(result);
        } else {
            require(PA_GetCollectionLength(result) == 1, "collection handoff invalidated");
            PA_DisposeCollection(result);
        }
        balanced("reference handoff balance");
    }
}

static void arrays()
{
    PA_Variable value = PA_CreateVariable(eVK_ArrayUnicode);
    PA_ResizeArray(&value, 3);
    for (int i = 0; i <= 3; ++i) {
        auto str = PA_CreateUnistring(utf16(i == 3 ? u"" : u"A\u65e5\U0001f600"));
        PA_SetStringInArray(value, i, &str);
        require(PA_GetStringInArray(value, i).fString == str.fString, "accepted transfer not shallow");
    }
    auto borrowed = PA_GetStringInArray(value, 1);
    C_TEXT scalar;
    scalar.setUTF16String(&borrowed);
    ARRAY_TEXT wrapper;
    BytePtr args[] = {reinterpret_cast<BytePtr>(&value)};
    wrapper.fromParamAtIndex(args, 1);
    auto replacement = PA_CreateUnistring(utf16(u"replacement"));
    PA_SetStringInArray(value, 1, &replacement);
    expect(PA_GetStringInArray(value, 1), u"replacement");
    PA_ResizeArray(&value, 0);
    wrapper.toParamAtIndex(args, 1);
    for (int i = 0; i <= 3; ++i)
        expect(PA_GetStringInArray(value, i), i == 3 ? u"" : u"A\u65e5\U0001f600");
    require(scalar.getUTF16Length() == 4, "borrowed scalar copy units");
    for (int i = 0; i <= 2; ++i)
        for (int j = i + 1; j <= 2; ++j)
            require(PA_GetStringInArray(value, i).fString != PA_GetStringInArray(value, j).fString,
                    "independent transferred owners required");
    auto rejected = PA_CreateUnistring(utf16(u"retained"));
    const size_t count = strings.size();
    PA_Variable wrong = PA_CreateVariable(eVK_Longint);
    PA_SetStringInArray(wrong, 0, &rejected);
    PA_SetStringInArray(value, -1, &rejected);
    PA_SetStringInArray(value, 4, &rejected);
    PA_Variable noData = {};
    noData.fType = eVK_ArrayUnicode;
    PA_SetStringInArray(noData, 0, &rejected);
    PA_SetStringInArray(value, 0, nullptr);
    require(strings.size() == count, "rejected transfer consumed ownership");
    expect(rejected, u"retained");
    PA_DisposeUnistring(&rejected);
    PA_Unistring nullEmpty = {};
    PA_SetStringInArray(value, 0, &nullEmpty);
    expect(PA_GetStringInArray(value, 0), u"");
    PA_ClearVariable(&value);
    balanced("array replacement/shrink/clear balances");
}

static void content()
{
    for (const char16_t *fixture : {u"ASCII", u"\u65e5\u672c", u"\U0001f600", u""}) {
        auto output = PA_CreateUnistring(utf16(u"old"));
        PA_Unistring *slot = &output;
        PluginBlock params = {};
        params.fResult = &slot;
        auto input = PA_CreateUnistring(utf16(fixture));
        PA_ReturnString(&params, input.fString);
        PA_DisposeUnistring(&input);
        expect(output, fixture);
        C_TEXT wrapper;
        wrapper.setUTF16String(&output);
        BytePtr args[] = {reinterpret_cast<BytePtr>(&output)};
        wrapper.toParamAtIndex(args, 1);
        expect(output, fixture);
        PA_DisposeUnistring(&output);
    }
    auto owner = newNode();
    CUTF8String json;
    ob_stringify(owner, &json);
    require(json == CUTF8String(reinterpret_cast<const uint8_t *>("{}")),
            "stringify must copy before clearing owned result");
    PA_DisposeObject(owner);
    balanced("content setters balance");
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        try {
            require(argc == 7, "only synthetic fixture arguments expected");
            allocatedEmpty = std::string(argv[2]) == "allocated";
            gCall4D = engine;
            std::string test = argv[1];
            if (test == "command") command(argc, argv);
            else if (test == "setters") setters();
            else if (test == "getters") getters();
            else if (test == "failures") failures();
            else if (test == "handoffs") handoffs();
            else if (test == "arrays") arrays();
            else if (test == "content") content();
            else throw std::runtime_error("unknown test");
            balanced("final ownership balances");
            std::cout << test << ": balanced\n";
            return 0;
        } catch (const std::exception &error) {
            std::cerr << error.what() << "\n";
            return 1;
        }
    }
}
