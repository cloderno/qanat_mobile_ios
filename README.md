# Qanat для iOS

iOS-версия мобильного приложения Qanat на SwiftUI — копия Android-приложения (`qanat_mobile_android`): вход и сброс
пароля, чаты с Канатом (ответы потоком, блоки-графики, таблицы, письма, презентации, голосовые, фото), документы
и шаблоны писем, голосовой режим, смарт-очки Meta (подключение через Meta AI, кнопка камеры, снимки и видео,
голосовые и разговор с очков, проверка очков, галерея), профиль и настройки, push. Языки — русский, казахский,
английский; темы — системная, светлая, тёмная.

## Сборка

Нужны Mac с Xcode 16+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig   # и заполнить
xcodegen generate
open Qanat.xcodeproj
```

Зависимости (Swift Package Manager) Xcode скачает сам: Meta Wearables Device Access Toolkit (`MWDATCore`,
`MWDATCamera`, `MWDATInputs`), Firebase Messaging, MarkdownUI. Минимальная версия iOS — 17.2.

### Секреты и настройки — не в git

- `Config/Secrets.xcconfig` — `DEVELOPMENT_TEAM`, `META_APP_ID`, `CLIENT_TOKEN` (из Meta Wearables Developer Center,
  те же, что `mwdat.*` в `local.properties` Android-версии). Шаблон — `Config/Secrets.xcconfig.example`.
- `Qanat/GoogleService-Info.plist` — из консоли Firebase (iOS-приложение `com.rating.qanatmobile` в том же проекте,
  что и Android). Без файла приложение работает, но push выключены. В Firebase нужно загрузить APNs-ключ (.p8).
- Адрес сервера — `QANAT_BASE_URL` в `Config/Shared.xcconfig` (как `qanat.baseUrl` на Android).

## Тесты

`QanatTests` (XCTest): ⌘U в Xcode или
`xcodebuild test -scheme Qanat -destination 'platform=iOS Simulator,name=iPhone 16'`.

## Устройство проекта

Feature-Based + Clean Architecture, как в Android-версии (подробно — `CLAUDE.md`):

- `Qanat/App` — точка входа (`QanatApp`), корень композиции `AppContainer` (вместо Hilt), навигация `AppRoot`,
  фоновая работа вошедшего пользователя `SignedInSession` (вместо `VoiceService`), push `PushSetup`.
- `Qanat/Feature/{Auth,Chat,Voice,Glasses,Settings,Profile}/{Presentation,Domain,Data}`.
- `Qanat/Core` — сеть (URLSession, refresh токена), Keychain/UserDefaults, аудио, контракты очков и реализация на Meta SDK,
  дизайн-система.
- `Qanat/Resources` — шрифты, картинки, `Localizable.strings`/`.stringsdict` (ru/kk/en). Строки сгенерированы из
  Android `strings.xml` скриптом `tools/convert_strings.py` — ключи те же; после правок строк в Android-версии:

  ```sh
  python tools/convert_strings.py ../qanat_mobile_android/app/src/main/res
  ```

## Отличия от Android

- Фон: разговор и команды с очков работают при заблокированном экране через фоновые режимы `audio`,
  `bluetooth-*` и `external-accessory`; постоянного уведомления службы, как на Android, нет.
- Настроек оптимизации батареи и каналов уведомлений на iOS нет — эти экраны и подсказки убраны.
- Включить Bluetooth из приложения нельзя — кнопка в проверке очков ведёт в «Настройки».
- Скачанные письма и презентации лежат в «Файлы» → «На iPhone» → Qanat.
- Сервер получает `platform: "ios"` при регистрации push-токена.

## Что проверить на устройстве

Код писался без Mac и ещё ни разу не собирался — первая сборка в Xcode наверняка покажет ошибки компиляции, их нужно
поправить. Помимо этого:

- Имена части API Meta Wearables SDK (типы нажатий кнопки, ошибки сессии, состояние дужек) сверены по документации
  и примеру SDK, но не по сборке — места помечены в `Core/Glasses/MetaGlassesControls.swift`.
- URL-схема Meta AI (`fb-viewapp`) и id Meta AI в App Store (`metaAiStoreURL`) — предположения.
- Ссылки сброса пароля (`https://qm.e-vko.kz/auth/reset`) открывают приложение, только если сервер отдаёт
  `apple-app-site-association` с `applinks` для `<TEAM_ID>.com.rating.qanatmobile`.
- Окна распознавания жестов кнопки очков и пороги громкости перенесены с Android и на iPhone не замерены.
