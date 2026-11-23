Release Launcher — трекер GitHub-релизов (macOS 12+, Intel / Apple Silicon)

Без Xcode, способ 1 (Terminal):
  xcode-select --install        (Command Line Tools, ~1–2 ГБ, один раз)
  ./build-intel.sh              (создаст "Release Launcher.app" рядом)

Без Xcode, способ 2 (GitHub Actions, ничего ставить не нужно):
  1) создайте репозиторий на GitHub и загрузите в него СОДЕРЖИМОЕ этой папки (включая скрытую .github)
  2) вкладка Actions → build → Run workflow
  3) скачайте артефакт ReleaseLauncher-universal.zip, распакуйте
  4) в Terminal: xattr -cr "Release Launcher.app"   (снимает карантин), затем правый клик → Открыть

Если macOS блокирует запуск: правый клик по .app → Открыть.
