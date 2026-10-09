import MouthyKit
import MouthyUpdates

// Sparkle lives only in the app executable; MouthyKit sees it through the AppUpdater hook.
AppUpdater.installed = SparkleUpdater()
await MouthyLauncher.main()
