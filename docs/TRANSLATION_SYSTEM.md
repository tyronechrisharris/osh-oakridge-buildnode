# OSCAR Translation System

This document is the implementation guide and maintenance checklist for localization in OSCAR. It explains how language selection crosses the React viewer and the server-rendered OpenSensorHub administration interface, how every type of translated resource is resolved, and every change required to add or restore a language without leaving partially translated screens.

The rules in this document apply to:

- the React/Next.js OSCAR viewer;
- the Vaadin OpenSensorHub administration and landing interfaces;
- generic and custom module configuration forms;
- Oak Ridge sensor and Lane System configuration forms;
- module names, descriptions, enum captions, validation messages, and custom controls; and
- context-sensitive Markdown help shown in the administration interface.

English is the canonical/base language. Spanish (`es`), French (`fr`), and Greek (`el`) are currently enabled. Adding a resource file does **not** enable a language by itself: a complete language must be registered in both UI stacks, supplied in every applicable resource family, added to the automated coverage checks, and manually verified.

## 1. Non-negotiable rules

Use this short list during every localization change:

1. Edit translation source files under `src/main/resources` or `web/oscar-viewer/src`; never edit generated copies under `build/resources`, `.next`, or an assembled distribution. (`dist/release` contains separately maintained deployment documentation and is not a runtime translation catalog.)
2. Keep the English resource as the canonical key catalog. Every supported language must contain the same keys.
3. Translate display text only. Do not translate configuration property names, module IDs, stored enum constants, protocol names, API field names, URLs, class names, or machine-readable values.
4. Preserve placeholders such as `{0}` and `{1}` exactly, including their numbers.
5. Store all resources as UTF-8 and use real accented characters.
6. Put Java configuration translations beside the configuration class's package. OSGi modules have separate class loaders; a central bundle cannot reliably discover every module resource.
7. Supply both `.label` and `.description` for every user-visible configuration field, including inherited, nested, and optional fields.
8. Add a localized README for every configuration package that supplies English help.
9. Search for hard-coded UI text. Adding keys to a bundle cannot translate text that never calls a translation function.
10. Extend the tests when adding a language, module, configuration class, or README. A green test suite only proves what its inventories enumerate.

Restoring a previously removed language follows exactly the same process as adding a new language. Do not merely put the language back in a selector: that produces a selectable but incomplete locale.

### 1.1 Upstream repository and submodule boundaries

The upstream build checkout is a Git superproject. Translation source is owned by three real submodules, while the build repository owns release integration and this cross-project guide:

| Checkout path | Owning repository responsibility |
| --- | --- |
| `include/osh-core` | Admin locale state, generic Vaadin controls, configuration-bundle lookup, localized help selection, global admin messages, and core tests |
| `include/osh-oakridge-modules` | Oak Ridge sensor/Lane bundles and READMEs, custom OSCAR forms, module inventories, and module tests |
| `web/oscar-viewer` | React locale registration, selector behavior, viewer JSON catalogs, and viewer tests/build |
| repository root | Integration documentation, release build, and the pinned submodule commit IDs |

A submodule is commonly checked out at a detached commit. Before committing, create a topic branch inside each changed submodule. Commit and propose changes to the owning repositories first; after those commits are available, update the superproject's submodule pointers and commit any root documentation. The practical dependency order is `osh-core`, `osh-oakridge-modules`, `oscar-viewer` (independent of the Java repositories), and finally the build superproject.

Do not flatten or copy submodule contents into the superproject. At the root, a changed submodule may appear only as `m include/osh-core`; inspect the actual files and diffs inside that submodule:

```sh
git -C include/osh-core status --short
git -C include/osh-core diff
git -C include/osh-oakridge-modules status --short
git -C include/osh-oakridge-modules diff
git -C web/oscar-viewer status --short
git -C web/oscar-viewer diff
```

The root commit must eventually pin submodule commits that collaborators and CI can fetch. A root gitlink pointing only to an unpublished local commit makes the integrated build unreproducible.

## 2. Architecture at a glance

OSCAR has two UI runtimes and four resource families:

```text
                         User chooses a language
                                  |
                    +-------------+-------------+
                    |                           |
             React viewer                 Vaadin admin UI
                    |                           |
          localStorage: language       Vaadin session locale
                    |                           |
                    +------ cookie: osh-language ------+
                    |                                  |
       web/oscar-viewer/src/locales          AdminI18n.java
                    |                                  |
              t("some.key")              +------------+------------+
                                          |            |            |
                                 AdminMessages   ConfigMessages   README_<lang>.md
                                  global UI       module forms      module help
```

The shared `osh-language` cookie is what lets a selection made in one UI become visible to the other after navigation or reload. The React viewer additionally uses `localStorage`; the Vaadin UI additionally uses its session.

Use the following API/resource for each kind of text:

| Text being translated | Runtime API | Resource family |
| --- | --- | --- |
| Generic admin action, heading, status, validation, dialog, or error | `AdminI18n.tr(key, args...)` | `AdminMessages*.properties` |
| Module name or description | `AdminI18n.trConfig(configClass, "module.name", fallback)` | package-local `ConfigMessages*.properties` |
| Config field label or tooltip/help description | Automatically resolved by `GenericConfigForm`, or explicitly with `trConfig` | package-local `ConfigMessages*.properties` |
| Enum caption | Automatically resolved by `GenericConfigForm` | package-local `ConfigMessages*.properties` beside the enum |
| Custom form control/message | `AdminI18n.trConfig(...)` | package-local `ConfigMessages*.properties` beside the form/config class |
| Admin module help tab | Automatically resolved by `ReadmePanel` | package-local `README*.md` |
| React viewer text | `const { t } = useLanguage(); t("key")` | `web/oscar-viewer/src/locales/*.json` |

## 3. Locale identity, selection, and persistence

### 3.1 Locale identifiers

The current implementation identifies a supported locale by its lowercase language code, such as `en`, `es`, `fr`, or `el`. Java may receive a full tag such as `es-MX` or `el-GR`, but `AdminI18n.normalize` compares only `Locale.getLanguage()` and maps it to the configured language-only locale.

Consequences:

- `es`, `es-ES`, and `es-MX` all resolve to the one supported Spanish resource set.
- The current design cannot distinguish regional variants such as `pt-BR` and `pt-PT`.
- Supporting multiple variants of one language requires an architectural change to compare full language tags, use variant-specific resource names, persist the full tag, and represent the same tags in the React `Locale` type.

For an ordinary new language, use one lowercase BCP 47/ISO language code consistently in Java, filenames, JSON registration, `localStorage`, and the cookie.

### 3.2 Shared cookie

Both interfaces use:

```text
osh-language=<language-code>
```

The React viewer writes it as:

```text
Path=/; Max-Age=31536000; SameSite=Lax
```

The admin language selector writes the same cookie and reloads the page. `Path=/` is essential because the viewer and admin interface are served from different URL paths.

The cookie stores only a language preference; it is not authentication or sensitive state. An unknown or malformed admin cookie is ignored, after which the normal session/request/default precedence continues.

### 3.3 Vaadin admin initialization order

`AdminUI` and `LandingUI` call `AdminI18n.initializeLocale(...)` as the UI is initialized. The effective locale is chosen in this order:

1. a supported value in the `osh-language` request cookie;
2. the locale saved in the current Vaadin session under `osh.admin.locale`;
3. `VaadinRequest.getLocale()`, normally derived from the browser request; then
4. English if the result is unsupported or missing.

The normalized value is written to both the Vaadin session and `UI.setLocale(...)`.

The admin selector is populated from `AdminI18n.getSupportedLocales()`. Its caption is the language's own name, for example `Español` rather than `Spanish`. Selecting a value:

1. saves the normalized locale in the Vaadin UI and session;
2. writes `localStorage.language` for the React viewer;
3. writes `osh-language` for both interfaces; and
4. reloads the page so every server-created component is reconstructed in the new language.

The supported-locale list order is also the admin selector order.

### 3.4 React viewer initialization order

`LanguageProvider` first takes a nonempty `localStorage.language`, or otherwise takes the `osh-language` cookie. It then uses that candidate if it names a registered translation object; otherwise it selects English. A nonempty but invalid local-storage value therefore currently shadows a valid cookie and produces English. Clearing the invalid local-storage entry allows the cookie to be considered on the next load.

The viewer currently does **not** derive its initial language from `navigator.language`. It persists the selected/fallback value to both storage mechanisms. The provider waits for client-side preference hydration before rendering its children, preventing a server/client hydration mismatch.

The `LanguageProvider` is mounted in `web/oscar-viewer/src/app/providers.tsx`, so `useLanguage()` is available throughout the application tree below it.

### 3.5 Cross-interface behavior

Because the two runtimes cannot update each other's already-rendered component trees, language synchronization occurs on selection plus navigation/reload:

- Choosing a language in the React viewer immediately rerenders components that use the context and leaves a cookie for the admin interface.
- Opening or reloading the admin interface then reads that cookie.
- Choosing a language in the admin interface writes both the cookie and React local storage, then reloads the admin page.
- Returning to or reloading the viewer uses the same language.

If one interface appears to have an old language, inspect both `localStorage.language` and the `osh-language` cookie, then reload the interface.

## 4. Server-rendered admin translations

The central implementation is:

```text
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/AdminI18n.java
```

It provides two deliberately separate lookup paths.

### 4.1 Global admin messages: `tr`

Use `AdminI18n.tr(...)` for text owned by the reusable admin UI rather than one module configuration package.

```java
import static org.sensorhub.ui.AdminI18n.tr;

Button save = new Button(tr("action.save"));
Label result = new Label(tr("message.itemsFound", count));
```

The bundle base name is fixed:

```text
org.sensorhub.ui.i18n.AdminMessages
```

Source files are located at:

```text
include/osh-core/sensorhub-webui-core/src/main/resources/org/sensorhub/ui/i18n/
    AdminMessages.properties       # English canonical catalog
    AdminMessages_es.properties    # Spanish
    AdminMessages_fr.properties    # French
    AdminMessages_el.properties    # Greek
```

For a new language `xx`, create `AdminMessages_xx.properties` with every key in `AdminMessages.properties`.

Arguments use literal numbered placeholders:

```properties
message.itemsFound={0} items found
```

`tr("message.itemsFound", 12)` replaces `{0}` with `12`. This is simple literal substitution, not `MessageFormat`:

- keep each placeholder number unchanged in every translation;
- do not add MessageFormat quoting rules;
- plural selection is not automatic;
- number and date localization is not automatic; and
- a repeated placeholder is replaced everywhere it occurs.

Java `ResourceBundle` performs its normal parent lookup, so a key missing from (for example) `AdminMessages_fr.properties` can silently resolve from the base English `AdminMessages.properties`. Only when the bundle/key cannot be resolved anywhere in that chain does `tr` return the key itself. A visible string such as `action.save` therefore indicates a missing/misspelled key or a packaging problem, while unexpected English can indicate an incomplete locale file. Exact parity tests are necessary because both cases otherwise fail softly.

### 4.2 Package-local configuration messages: `trConfig`

Configuration metadata belongs to the module that owns the configuration class. `AdminI18n.trConfig(configClass, keySuffix, fallback)` derives both the bundle and full key from that class.

For this class:

```text
com.botts.impl.system.lane.config.LaneConfig
```

the lookup is:

```text
bundle: com.botts.impl.system.lane.config.i18n.ConfigMessages
key:    LaneConfig.<keySuffix>
```

For a nested class, Java's `$` separator is converted to a dot. For example:

```text
Java class: LaneConfig$AddressRange
key prefix: LaneConfig.AddressRange
```

The bundle is loaded with `configClass.getClassLoader()`. This is important in the OSGi deployment: resources must be packaged in the same module/JAR and in the package derived from the class. A similarly named bundle elsewhere in the repository is not a substitute.

Java `ResourceBundle` first performs normal locale-parent lookup. A key missing from `ConfigMessages_fr.properties` can therefore resolve from the base English `ConfigMessages.properties`. If the key or bundle cannot be found anywhere in the chain, `trConfig` returns the caller-supplied fallback, normally annotation/provider English text. Both paths make missing translations less visually obvious than a raw global key. Key-parity tests and manual language review are therefore required.

### 4.3 Generic field labels and descriptions

`GenericConfigForm` automatically translates reflected public configuration fields. `BaseProperty` exposes the field's actual declaring class and field name. The lookup suffixes are:

```text
<fieldName>.label
<fieldName>.description
```

For example:

```properties
LaneConfig.autoDelete.label=Delete Data on Lane Removal
LaneConfig.autoDelete.description=Automatically delete all records for this lane when the lane is removed
```

The English fallback is:

- the field's configured/annotated label, or a prettified Java property name if no label exists; and
- the field's configured/annotated description for help text/tooltips.

The declaring class, not necessarily the concrete form's top-level class, controls the resource location and key. If `ChildConfig` inherits `timeout` from `BaseConfig`, put `BaseConfig.timeout.*` in the bundle beside `BaseConfig`. Do not duplicate it under `ChildConfig` unless `ChildConfig` redeclares the field.

This automatic path is used for scalar controls, subforms, list controls, and tab/section captions that are built from reflected properties.

### 4.4 Nested configuration classes

Include each enclosing class in the key prefix, separated by dots. For example, the Lane configuration includes:

```properties
AspectRPMConfig.AddressRange.from.label=From
AspectRPMConfig.AddressRange.from.description=First device address to scan
RapiscanRPMConfig.EMLConfig.laneWidth.label=Lane Width (m)
RapiscanRPMConfig.EMLConfig.laneWidth.description=Width of the lane in meters
```

Use the actual binary nesting chain. Moving a nested class changes its generated translation prefix and requires moving all of its keys.

### 4.5 Module picker names and descriptions

`ModuleTypeSelectionPopup` translates each discovered module provider through its configuration class:

```properties
LaneConfig.module.name=Lane System
LaneConfig.module.description=Specialized Sensor System module used as the parent system for RPM and video drivers in a lane
```

Required suffixes are:

```text
module.name
module.description
```

Fallback values come from the module provider's `getModuleName()` and `getModuleDescription()`.

This is the text a user sees before opening a new-module form. A module is not completely localized if its form fields are translated but its module-picker entry is not.

### 4.6 Communication-provider forms

`CommProviderConfigForm` uses the same declaring-class field lookups for the provider property, and it translates each selectable provider module through that provider's configuration class. A communication provider therefore needs:

- its `module.name` and `module.description` entries;
- `.label` and `.description` entries for all displayed fields; and
- any applicable README help.

### 4.7 Enum values

Enum controls retain the Java enum constant as the stored value and translate only its caption. For an enum class and constant:

```java
public enum Mode { AUTOMATIC, MANUAL }
```

put these keys in the bundle beside the enum class:

```properties
Mode.value.AUTOMATIC=Automatic
Mode.value.MANUAL=Manual
```

The enum class can be nested; the same nested-class prefix rule applies. The constant name is case-sensitive and must not be translated in the key. The fallback is `enumValue.toString()`.

### 4.8 Selectable custom types

Custom forms such as the Lane form present concrete configuration subtype choices. Their caption suffix is:

```text
type.name
```

Examples:

```properties
AspectRPMConfig.type.name=Aspect
RapiscanRPMConfig.type.name=Rapiscan
SonyCameraConfig.type.name=Sony
CustomCameraConfig.type.name=Custom
```

This changes only the visible option. It does not change the Java class or serialized type.

### 4.9 Custom form controls and messages

Text created directly by custom Java forms is not seen by reflection and must call `trConfig` explicitly. Use a stable `ui` namespace:

```properties
SiteDiagramForm.ui.pixelCoordinates=Pixel coordinates
OSCARServiceForm.ui.saveSuccess=Configuration saved
```

```java
new Label(trConfig(
    SiteDiagramForm.class,
    "ui.pixelCoordinates",
    "Pixel coordinates"));
```

The form class determines the resource package and full prefix. Add the key to the English bundle and every supported locale at the same time. Include buttons, headings, inline guidance, confirmation text, error/success notifications, empty states, and accessible labels.

### 4.10 Validation and framework messages

Validation and reusable admin-framework messages belong in `AdminMessages`, not an individual sensor bundle, when the wording is shared across module types. Module-specific validation belongs beside the responsible config/form class in `ConfigMessages`.

Do not build a translated sentence by concatenating fragments. Word order changes between languages. Prefer one complete resource with numbered placeholders:

```properties
validation.range=Value must be between {0} and {1}
```

## 5. Context-sensitive README/help localization

`ReadmePanel` displays Markdown documentation for the configuration class currently being edited. It reads resources relative to that class using UTF-8.

### 5.1 Canonical file layout

Place help beside the configuration class's resource package:

```text
src/main/resources/<configuration-package>/i18n/
    README.md
    README_es.md
    README_fr.md
    README_el.md
```

For example:

```text
include/osh-oakridge-modules/sensors/sensorhub-system-lane/
  src/main/resources/com/botts/impl/system/lane/config/i18n/
    README.md
    README_es.md
    README_fr.md
    README_el.md
```

For a new language `xx`, add `README_xx.md` in every `i18n` directory that contains the English `README.md`.

### 5.2 Resolution order

For a non-English selected language `xx`, candidates are checked in this order:

1. `i18n/README_xx.md` — canonical localized location;
2. `README_xx.md` — legacy location beside the class;
3. `i18n/README.md` — canonical English fallback; and
4. `README.md` — legacy English fallback.

For English, only the two English candidates are checked.

This means missing localized help safely falls back to English. That fallback is intentional for runtime resilience, but a supported language is not complete until the localized file exists and the automated README inventory checks it.

### 5.3 Writing translated help

Each translated README must preserve the English document's technical meaning and structure:

- keep configuration property names, literal values, commands, paths, ports, protocol terms, and code blocks unchanged unless the literal itself is locale-dependent;
- translate headings, prose, cautions, examples' explanatory text, and image alt text;
- keep links valid relative to the resource location;
- preserve Markdown tables, fenced code blocks, and inline code delimiters;
- explain every field and operational constraint covered by the English file; and
- update every language when the English help changes.

The files are parsed at runtime by the admin Markdown component. Verify rendering, not just raw text.

### 5.4 Missing-help screen

If no README exists, `ReadmePanel` displays localized instructions from `AdminMessages`. `ReadmePanel.generateInstructions(...)` derives the expected localized filenames from `AdminI18n.getSupportedLocales()`, so registering a new admin locale automatically adds its filename to the list. The `readme.missing.localized` message uses `{0}` for that generated list; preserve this placeholder in every translation.

## 6. React/Next.js viewer translations

The viewer implementation is centered on:

```text
web/oscar-viewer/src/app/contexts/LanguageContext.tsx
web/oscar-viewer/src/app/_components/LanguageSelector.tsx
web/oscar-viewer/src/locales/en.json
web/oscar-viewer/src/locales/es.json
web/oscar-viewer/src/locales/fr.json
web/oscar-viewer/src/locales/el.json
web/oscar-viewer/scripts/validate-locales.js
```

### 6.1 Translation keys

`en.json` is the canonical viewer catalog. Locale files are flat JSON string maps:

```json
{
  "save": "Save",
  "cancel": "Cancel"
}
```

A component retrieves a value with:

```tsx
import { useLanguage } from '@/app/contexts/LanguageContext';

const { t } = useLanguage();
return <Button>{t('save')}</Button>;
```

`t(key, params)` looks up the selected catalog, falls back to `en.json`, and finally returns the raw key when neither catalog defines it. Optional named parameters replace tokens such as `{username}` and `{count}`. It does not choose plurals, format rich text, or resolve nested objects. Therefore:

- every registered locale JSON file must have exact key parity with `en.json`;
- every locale must preserve exactly the named placeholders used by the English value;
- dynamic values and plural-sensitive sentences must still be composed carefully by the caller;
- an English value in another language can indicate that the selected catalog is missing a key and the fallback was used;
- a raw key visible in the UI means both the selected and English catalogs are missing that key; and
- `npm run validate:locales` rejects missing, extra, empty, non-string, or placeholder-incompatible values.

The locale validator runs automatically during `prebuild`, so `npm run build` enforces complete English, Spanish, French, and Greek catalogs before compiling the viewer.

### 6.2 Registering a locale

A JSON file alone is inert. `LanguageContext.tsx` must:

1. import it;
2. add its code to the `Locale` union; and
3. add it to the `translations` map.

`LanguageSelector.tsx` imports the shared `Locale` type, so adding a code to that union updates the change-handler type. The selector must still render the language's native name for the selected value and add a corresponding `MenuItem`.

Use the language's native name in the selector (`Italiano`, `Deutsch`, `Português`), not an English translation of the name.

### 6.3 Hard-coded viewer strings

Only components that call `t(...)` are translated. The viewer still contains user-facing literal English in several screens and controls. When completing or adding a language, systematically audit all TS/TSX files for:

- JSX text nodes;
- button, menu, tab, dialog, and tooltip labels;
- placeholders and helper text;
- error, warning, success, empty-state, and loading messages;
- accessibility values such as `aria-label`, `alt`, and `title`;
- chart legends, table headings, filter labels, report names, and export labels;
- strings passed through component props or constructed in helper functions; and
- server-provided values that are actually presentation labels rather than domain data.

Move each user-facing literal into `en.json`, add it to every locale, and replace the literal with `t(...)`. Do not translate operational identifiers or values received from sensors simply because they are English words.

Useful audit starting points include the server-management, national-view, lane-view, event-details, adjudication, report, map, and dashboard components. A search is only a starting point; code review and screen-by-screen testing are still necessary.

### 6.4 Dates, times, numbers, and document metadata

String translation and locale-sensitive formatting are separate concerns. Some viewer code currently uses `navigator.language` or the browser default for `toLocaleString`. The client updates `document.documentElement.lang` to the selected language, but the server-rendered root layout and static metadata start in English. Dates, numbers, and static metadata do not all automatically follow the selected OSCAR language.

For complete locale support, audit and update:

- `Date.toLocaleDateString`, `toLocaleTimeString`, and `toLocaleString` calls;
- `Intl.DateTimeFormat`, `Intl.NumberFormat`, and relative-time formatting;
- units and decimal/group separators;
- the root `<html lang>` value;
- page titles and metadata descriptions;
- any generated reports/exports; and
- timezone labels, which must remain semantically correct even when translated.

The preferred future pattern is to expose a BCP 47 formatting tag from `LanguageContext` and pass it explicitly to `Intl` formatters. Until that is implemented consistently, adding a translation JSON file does not guarantee dates and numbers follow the selected language.

## 7. Current source resource inventory

This inventory identifies the catalogs that a newly supported language must cover. If a new bundle or README directory is added later, add it to this section and to the automated inventories.

### 7.1 Global admin catalog

```text
include/osh-core/sensorhub-webui-core/src/main/resources/
  org/sensorhub/ui/i18n/AdminMessages.properties
```

### 7.2 Core configuration catalogs

All paths below are under `include/osh-core/sensorhub-core/src/main/resources/`:

```text
org/sensorhub/api/comm/i18n/ConfigMessages.properties
org/sensorhub/api/module/i18n/ConfigMessages.properties
org/sensorhub/api/sensor/i18n/ConfigMessages.properties
org/sensorhub/impl/comm/i18n/ConfigMessages.properties
org/sensorhub/impl/module/i18n/ConfigMessages.properties
org/sensorhub/impl/sensor/i18n/ConfigMessages.properties
```

### 7.3 Oak Ridge sensor and system catalogs

```text
include/osh-oakridge-modules/sensors/sensorhub-driver-aspect/
  src/main/resources/com/botts/impl/sensor/aspect/i18n/ConfigMessages.properties
  src/main/resources/com/botts/impl/sensor/aspect/comm/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/sensorhub-driver-ffmpeg/
  src/main/resources/org/sensorhub/impl/sensor/ffmpeg/config/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/sensorhub-driver-kromek-d3s/
  src/main/resources/com/botts/impl/sensor/kromek/d3s/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/sensorhub-driver-kromek-d5/
  src/main/resources/com/botts/impl/sensor/kromek/d5/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/sensorhub-driver-proximity/
  src/main/resources/com/botts/impl/sensor/proximity/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/sensorhub-driver-rapiscan/
  src/main/resources/com/botts/impl/sensor/rapiscan/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/sensorhub-driver-rs350/
  src/main/resources/com/botts/impl/sensor/rs350/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/sensorhub-driver-tstar/
  src/main/resources/org/sensorhub/impl/sensor/tstar/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/sensorhub-system-lane/
  src/main/resources/com/botts/impl/system/lane/config/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/zwave/sensorhub-driver-homseer-ds100-g8/
  src/main/resources/com/botts/impl/sensor/ds100/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/zwave/sensorhub-driver-wadwaz-1/
  src/main/resources/com/botts/impl/sensor/wadwaz1/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/zwave/sensorhub-driver-wapirz-1/
  src/main/resources/com/botts/impl/sensor/wapirz1/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/zwave/sensorhub-driver-zooz-zse18-800lr/
  src/main/resources/com/botts/impl/sensor/zse18/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/zwave/sensorhub-driver-zw100-multisensor-6/
  src/main/resources/com/botts/impl/sensor/zw100/i18n/ConfigMessages.properties

include/osh-oakridge-modules/sensors/zwave/sensorhub-zwave-comms/
  src/main/resources/com/botts/sensorhub/impl/zwave/comms/i18n/ConfigMessages.properties
```

Each of these sensor/system package directories also currently has `README.md`, `README_es.md`, `README_fr.md`, and `README_el.md` in the same `i18n` directory.

### 7.4 OSCAR custom-form catalog

```text
include/osh-oakridge-modules/tools/sensorhub-webui-oscar/
  src/main/resources/com/botts/ui/oscar/forms/i18n/ConfigMessages.properties
```

### 7.5 Core communication help

The shared core communication configuration currently supplies help at:

```text
include/osh-core/sensorhub-core/src/main/resources/
  org/sensorhub/impl/comm/i18n/README.md
  org/sensorhub/impl/comm/i18n/README_es.md
  org/sensorhub/impl/comm/i18n/README_fr.md
  org/sensorhub/impl/comm/i18n/README_el.md
```

### 7.6 Viewer catalogs

```text
web/oscar-viewer/src/locales/en.json
web/oscar-viewer/src/locales/es.json
web/oscar-viewer/src/locales/fr.json
web/oscar-viewer/src/locales/el.json
```

## 8. Complete procedure to add or restore a language

The following example adds Italian (`it`). Substitute the chosen code and native name for another language.

### Step 1: Define the locale contract

Before translating files, record:

- language code: `it`;
- native selector name: `Italiano`;
- Java locale: `Locale.ITALIAN` or `new Locale("it")`;
- whether one generic language is sufficient; and
- who will review domain terminology for sensors, radiation portals, lanes, networking, and adjudication.

If separate regional variants are required, stop and update the language-tag architecture first. Do not represent two variants with the same language-only normalization.

### Step 2: Register the admin locale

Add the locale to `SUPPORTED_LOCALES` in `AdminI18n.java`:

```java
private static final List<Locale> SUPPORTED_LOCALES = Arrays.asList(
    Locale.ENGLISH,
    new Locale("es"),
    Locale.FRENCH,
    new Locale("el"),
    Locale.ITALIAN
);
```

This enables normalization, cookie recognition, `ResourceBundle` selection, and the admin selector. Place it in the desired selector order.

Add/adjust unit tests for normalization and cookie parsing. Verify `it`, `it-IT`, and an unsupported language.

### Step 3: Add the global admin catalog

Copy the canonical key structure from:

```text
AdminMessages.properties
```

to:

```text
AdminMessages_it.properties
```

Translate every value and preserve every key and placeholder. Do not use the Spanish, French, or Greek file as the catalog because it could already be missing a newly added English key.

Update `AdminI18nTest` so key parity includes Italian. Add focused assertions for representative navigation, action, validation, and parameterized messages.

### Step 4: Add every configuration catalog

For every base `ConfigMessages.properties` in the inventory, add:

```text
ConfigMessages_it.properties
```

Each translated catalog must have exact key parity with its local English base. Do not merge bundles from different packages or modules.

Verify especially:

- `module.name` and `module.description`;
- every field's `.label` and `.description` pair;
- nested configuration keys;
- every `value.<ENUM_CONSTANT>`;
- every `type.name` entry;
- custom `ui.*` text; and
- messages with `{0}`, `{1}`, and later placeholders.

Update `LaneConfigI18nTest`, `OakridgeSensorI18nTest`, and the core bundle parity coverage to include Italian. Prefer refactoring hard-coded `es`/`fr` loops into a shared list of required non-English locales so the next language requires one test-list change.

### Step 5: Add all localized help

For every canonical `README.md` enumerated by the test inventory, add:

```text
README_it.md
```

Translate the complete content using the rules in section 5.3. Do not copy English unchanged merely to satisfy a presence test.

Update the README inventories and assertions in `OakridgeSensorI18nTest` and `ReadmePanelTest`. Add coverage for:

- Italian is chosen when it exists;
- English is used when a localized file is intentionally absent in a fixture;
- files are decoded as UTF-8; and
- the candidate order remains canonical directory first, then legacy.

Verify that the missing-help UI automatically shows `README_it.md` as an expected file after the locale is registered.

### Step 6: Register the viewer locale

Create:

```text
web/oscar-viewer/src/locales/it.json
```

using `en.json` as the exact key catalog.

Then update `LanguageContext.tsx`:

```tsx
import it from '../../locales/it.json';

export type Locale = 'en' | 'es' | 'fr' | 'el' | 'it';

const translations: Record<Locale, Translations> = {
  en,
  es,
  fr,
  el,
  it,
};
```

`LanguageSelector.tsx` already uses the exported `Locale` type in its change handler. Add both the selected-value caption and menu item:

```tsx
if (selected === 'it') return 'Italiano';
// ...
<MenuItem value="it">Italiano</MenuItem>
```

A useful follow-up is to define a single locale metadata list and generate the selector from it. Until that refactor occurs, the context's locale/translation map and the selector's captions/items must be changed together.

### Step 7: Audit all viewer text and formatting

Search every TS/TSX file, not only files already importing `useLanguage`. Replace literal user-facing text with translation keys and populate the keys in **all** languages, including English, Spanish, French, Greek, and Italian.

Then inspect every date/number formatter and the document language/metadata. Make formatting use the selected language explicitly where required. Test long translations and accented characters at supported screen sizes.

### Step 8: Validate resource integrity automatically

At minimum, the automated checks for a new locale must prove:

- every localized Java `.properties` file has the exact English key set;
- every localized viewer JSON file has the exact `en.json` key set;
- placeholders in each value match the English placeholder set;
- all expected files are UTF-8 and nonempty;
- every registered locale has both admin and viewer registration;
- every inventoried module has its localized README;
- every public configuration field expected in a form has an English key pair;
- every translated module has module name/description keys; and
- representative lookups return translated values rather than fallbacks.

Do not rely only on a translation being different from English. Brand names, acronyms, and some technical terms legitimately remain identical.

### Step 9: Run builds and tests

From the repository root:

```sh
./gradlew :osh-core:sensorhub-webui-core:test :sensorhub-webui-oscar:test
git diff --check
git -C include/osh-core diff --check
git -C include/osh-oakridge-modules diff --check
git -C web/oscar-viewer diff --check
```

Run the checks after adding new files to the index, because ordinary `git diff --check` does not inspect untracked files. The root check alone is insufficient: it sees submodule commit pointers, not the file-level changes inside the submodules.

From `web/oscar-viewer`:

```sh
npm run validate:locales
npm run lint
npm run build
npm test
```

The Cypress suite may require its configured runtime services. For release-equivalent integration and packaging, run the repository's canonical build:

```sh
./build-all.sh
```

On Windows, use `build-all.bat`.

### Step 10: Perform end-to-end manual QA

Test with a clean browser profile or after clearing both the language cookie and local storage.

1. Open the viewer with no saved preference; verify the documented English default.
2. Select Italian in the viewer; verify immediate viewer updates, `localStorage.language=it`, and `osh-language=it`.
3. Open the admin panel; verify it starts in Italian.
4. In the admin panel, right-click under Sensors, choose New System, select Lane System, and complete every field.
5. Verify the module name/description, all top-level fields, nested RPM/camera forms, type choices, enum choices, tooltips, validation, buttons, errors, and success messages.
6. Open the Lane help panel and verify `README_it.md`, Markdown layout, links, and code blocks.
7. Repeat creation/editing for every Oak Ridge sensor and Z-Wave module, including its communication configuration and help.
8. Change language in admin; verify the page reloads and the viewer later uses the same choice.
9. Refresh, sign out/in if applicable, open a new tab, and navigate between viewer/admin paths to verify persistence.
10. Set an unsupported cookie value and verify English fallback without a crash.
11. Temporarily exercise a test fixture with no Italian README and verify English help fallback.
12. Inspect event, national, lane, report, map, server, and adjudication screens for literal English.
13. Verify dates, times, numbers, units, page title, `html[lang]`, tooltips, and accessibility labels.
14. Check browser and server logs for missing resources, JSON errors, encoding problems, and hydration warnings.
15. Test at narrow and wide layouts; translated text is often longer than English.

### Step 11: Review and ship as one complete change

The review should include registration code, every resource family, automated inventories, tests, and this documentation if the inventory changed. Avoid shipping a selectable language in one change and its translations later; users would encounter a knowingly partial interface.

## 9. Procedures for ongoing development

### 9.1 Add a new global admin string

1. Choose a semantic, stable key; do not use the English sentence as the key.
2. Add it to `AdminMessages.properties` and every locale-specific `AdminMessages_<code>.properties`.
3. Replace the Java literal with `tr("key")` or `tr("key", args...)`.
4. Preserve placeholder sets in every locale.
5. Test the screen in every language.

### 9.2 Add a configuration field

1. Determine the Java field's declaring class.
2. Find/create `<declaring-package>/i18n/ConfigMessages.properties` in that module's `src/main/resources`.
3. Add `<ClassPrefix>.<field>.label`.
4. Add `<ClassPrefix>.<field>.description`.
5. Add the same keys to every locale-specific catalog.
6. If the class is not covered by the config-form inventory test, add it.
7. Open the real form and check label, tooltip/help, validation, and layout.

Descriptions are required even when the UI can technically render without them. They are user help, not optional translator comments.

### 9.3 Add a new module or sensor driver

1. Add its configuration class to the appropriate test inventory.
2. Add package-local `ConfigMessages.properties` and every supported locale file.
3. Add `module.name` and `module.description`.
4. Add label/description pairs for every form field, including inherited and nested fields.
5. Add enum and selectable subtype captions.
6. Translate all custom form UI.
7. Add `README.md` plus one `README_<code>.md` per supported non-English locale.
8. Add its README/package to the documentation test inventory.
9. Test discovery in the New Sensor/New System/module picker and complete the entire form.

### 9.4 Change an English string

Changing the English value does not invalidate or update existing translations automatically.

1. Decide whether the meaning changed or only the English wording changed.
2. If meaning changed, update every language and help document in the same change.
3. If placeholders changed, update their complete set in every locale.
4. Notify/review with a domain translator when technical meaning changed.
5. Re-run parity and UI tests.

### 9.5 Remove a key, field, module, or language

Remove corresponding entries from all locales, tests, inventories, selectors, and documentation together. Before removing a language, consider stored preferences: old cookies/local storage will be rejected by the viewer map/admin supported list and fall back to English.

## 10. Automated test responsibilities

Current localization tests are:

```text
include/osh-core/sensorhub-webui-core/src/test/java/org/sensorhub/ui/AdminI18nTest.java
include/osh-core/sensorhub-webui-core/src/test/java/org/sensorhub/ui/ReadmePanelTest.java
include/osh-oakridge-modules/tools/sensorhub-webui-oscar/src/test/java/
  com/botts/ui/oscar/forms/LaneConfigI18nTest.java
  com/botts/ui/oscar/forms/OakridgeSensorI18nTest.java
```

Their current roles are:

- `AdminI18nTest`: global lookups, placeholder replacement, normalization/fallback, global key coverage, and selected core config bundle completeness;
- `ReadmePanelTest`: localized README selection and English fallback;
- `LaneConfigI18nTest`: Lane sample lookup, locale key parity, and English coverage of form fields; and
- `OakridgeSensorI18nTest`: explicit bundle/module/README/config-class inventories, module metadata, translated document presence, and English label/description coverage for public form fields.

Important limitation: some locale and module lists are explicit. A new file on disk is not automatically proof that a test checks it, and a newly added module may be invisible to coverage until its class/bundle/README is registered in the test inventory. Update tests first-class, not as an afterthought.

The viewer's `scripts/validate-locales.js` parses every registered `src/locales/*.json` file, requires exact key parity with `en.json`, and compares placeholder tokens. It runs directly through `npm run validate:locales` and automatically from `prebuild`. Cypress should also switch languages and inspect representative screens.

## 11. Audit techniques

These commands help locate likely gaps. They produce false positives and cannot replace review:

```sh
# Java UI construction and caption sites
rg -n 'new (Button|Label|CheckBox|TextField)|setCaption|setDescription|showError|showNotification' \
  include/osh-core/sensorhub-webui-core/src/main/java \
  include/osh-oakridge-modules

# React components that already use the translation context
rg -l 'useLanguage\(' web/oscar-viewer/src --glob '*.{ts,tsx}'

# Locale-sensitive formatting that may follow the browser instead of OSCAR
rg -n 'navigator\.language|toLocale(String|DateString|TimeString)|Intl\.' \
  web/oscar-viewer/src --glob '*.{ts,tsx}'

# All canonical Java catalogs and help documents
find include -path '*/src/main/resources/*/i18n/ConfigMessages.properties' -print | sort
find include -path '*/src/main/resources/*/i18n/README.md' -print | sort

# Generated resource copies: inspect if debugging packaging, never edit
find . -path '*/build/resources/*/ConfigMessages*.properties' -print
```

For React literal text, inspect JSX text nodes and user-facing string props manually. A broad quoted-string search also finds imports, CSS values, routes, API constants, and test identifiers, so every result needs classification.

## 12. Fallback behavior reference

| Situation | Result |
| --- | --- |
| Unsupported/missing admin locale | English locale |
| Cookie contains a supported regional tag such as `fr-CA` | Supported language-only French locale |
| Missing global `AdminMessages` key | Raw key returned (after normal `ResourceBundle` parent lookup) |
| Missing config `ConfigMessages` key/bundle | Caller-provided annotation/provider/English fallback |
| Missing selected viewer JSON key | Raw key returned; no English lookup |
| Stored viewer code is not in the translations map | English selected and persisted |
| Missing localized README | English README |
| No localized or English README | Localized missing-help instructions |

Fallbacks prevent crashes; they are not evidence that a language is complete.

## 13. File format and translator guidance

### Java `.properties`

- Encode as UTF-8.
- Keep the key to the left of the first unescaped `=` or `:` unchanged.
- Preserve leading spaces only when they are intentional.
- Escape literal separators/backslashes where required by Java properties syntax.
- Avoid duplicate keys; later values can silently replace earlier ones.
- Preserve `{0}`, `{1}`, and other placeholders exactly.
- Keep technical literals in backticks only in Markdown; properties values are plain text unless their consumer renders markup.

### Viewer JSON

- Use valid UTF-8 JSON with double-quoted keys and string values.
- Do not add comments or trailing commas.
- Keep exact key parity with `en.json`.
- Escape embedded double quotes and control characters.
- Remember that the current `t` function supports strings only.

### Markdown help

- Encode as UTF-8.
- Preserve code fences, inline code, links, tables, and meaningful emphasis.
- Keep code/config examples executable.
- Translate image alt text and prose around screenshots.
- Review rendered output in the admin UI.

### Terminology

Maintain a reviewed terminology list for high-impact concepts such as lane, portal monitor, occupancy, adjudication, alarm, gamma/neutron measurements, detector, communication provider, and sensor status. The same English concept should not receive unrelated translations in the viewer, config bundles, and READMEs.

## 14. Troubleshooting

### The UI displays a key such as `action.save`

The global admin key or viewer key is missing, misspelled, or not packaged. Identify which runtime rendered it, compare the selected locale catalog with the English catalog, and inspect the built artifact if source is correct.

### A config field stays in English while the rest of the form translates

Likely causes:

- the localized key is absent and Java used the English base bundle, or `trConfig` used its English fallback;
- the key uses the concrete config class instead of the field's declaring class;
- a nested-class segment is missing;
- the bundle is in the wrong package/module;
- the field name or case does not match Java; or
- the built OSGi bundle is stale.

Use the declaring class and exact field name exposed by `BaseProperty`, then derive the bundle/key exactly as described in section 4.2.

### Module picker entry is English but its fields translate

Add/verify `<ConfigClass>.module.name` and `<ConfigClass>.module.description`. Field keys and module metadata are independent.

### Enum or subtype options stay in English

For enums, verify `<EnumClass>.value.<CONSTANT>`. For custom selectable configuration types, verify `<ConfigClass>.type.name`. These keys belong beside the enum/subtype class, not necessarily the parent form.

### README always appears in English

Verify the selected normalized language, filename case (`README_xx.md`), canonical `i18n` location, config class package, resource inclusion in the JAR, and that the module was rebuilt/redeployed.

### Viewer and admin disagree on language

Inspect `localStorage.language`, the `osh-language` cookie path/value, and the Vaadin session. Ensure the code is registered in both `LanguageContext` and `AdminI18n`. Reload both interfaces after correcting state.

### Accented characters are corrupted

Confirm UTF-8 source encoding, resource-copy settings, browser response encoding, and that the file was not saved by an editor using a legacy code page. `ReadmePanel` explicitly decodes README bytes as UTF-8.

### A source change has no runtime effect

Do not patch a generated `build/resources` copy. Rebuild the owning Gradle module or the viewer, recreate/redeploy the package or container, and verify the final JAR/static bundle contains the changed source resource.

## 15. Definition of done for a supported language

A language is supported only when every applicable item below is complete:

- [ ] A stable language code and native display name are defined.
- [ ] The locale is registered in `AdminI18n.SUPPORTED_LOCALES`.
- [ ] Admin normalization, cookie, and fallback tests include it.
- [ ] `AdminMessages_<code>.properties` exists with exact key and placeholder parity.
- [ ] Every inventoried `ConfigMessages.properties` has a complete locale sibling.
- [ ] Module names and descriptions are translated.
- [ ] All form labels and descriptions, including inherited/nested fields, are translated.
- [ ] Enum values and selectable subtype captions are translated.
- [ ] Custom Java form controls, validation, errors, and notifications are translated.
- [ ] Every inventoried English README has `README_<code>.md` with complete translated content.
- [ ] Missing-help instructions mention the new supported file where appropriate.
- [ ] `<code>.json` exists with exact viewer key parity.
- [ ] The locale is imported and registered in `LanguageContext`.
- [ ] The locale appears by native name in `LanguageSelector`.
- [ ] Every viewer screen was audited for hard-coded user-facing English.
- [ ] Dates, times, numbers, units, metadata, `html[lang]`, and accessibility text were audited.
- [ ] Java localization tests pass.
- [ ] Viewer lint, build, locale validation, and Cypress tests pass.
- [ ] The canonical repository build passes.
- [ ] The full Lane System creation flow passes in the new language.
- [ ] Every Oak Ridge sensor/communication form and help panel is manually sampled or tested.
- [ ] Cross-interface selection and persistence work in both directions.
- [ ] English and unsupported-locale fallbacks still work.
- [ ] A fluent reviewer and a domain reviewer approve terminology and technical meaning.
- [ ] No generated output was edited as source.
- [ ] This inventory is updated if new resource locations were introduced.

## 16. Primary implementation references

Use these files when behavior and documentation appear to disagree:

```text
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/AdminI18n.java
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/AdminUI.java
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/LandingUI.java
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/GenericConfigForm.java
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/CommProviderConfigForm.java
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/ModuleTypeSelectionPopup.java
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/ReadmePanel.java
include/osh-core/sensorhub-webui-core/src/main/java/org/sensorhub/ui/data/BaseProperty.java

include/osh-oakridge-modules/tools/sensorhub-webui-oscar/src/main/java/
  com/botts/ui/oscar/forms/LaneConfigForm.java
  com/botts/ui/oscar/forms/SiteDiagramForm.java
  com/botts/ui/oscar/forms/OSCARServiceForm.java

web/oscar-viewer/src/app/contexts/LanguageContext.tsx
web/oscar-viewer/src/app/_components/LanguageSelector.tsx
web/oscar-viewer/src/app/providers.tsx
web/oscar-viewer/src/locales/en.json
web/oscar-viewer/scripts/validate-locales.js
```

When implementation behavior changes, update this guide and the relevant tests in the same change.
