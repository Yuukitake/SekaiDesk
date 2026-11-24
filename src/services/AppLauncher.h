#pragma once
// AppLauncher — manages pinned dock apps from config/sekaidesk.json and
// launches targets natively on Windows via ShellExecuteW.

#include <QObject>
#include <QVariantList>
#include <QVariantMap>

class SettingsStore;

class AppLauncher : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList pinnedApps READ pinnedApps NOTIFY pinnedAppsChanged)
    Q_PROPERTY(QVariantList installedApps READ installedApps NOTIFY installedAppsChanged)
    Q_PROPERTY(QVariantList hiddenApps READ hiddenApps NOTIFY hiddenAppsChanged)
    Q_PROPERTY(QVariantList drawerFolders READ drawerFolders NOTIFY drawerFoldersChanged)

public:
    explicit AppLauncher(SettingsStore* settings, QObject* parent = nullptr);

    QVariantList pinnedApps() const { return m_pinnedApps; }
    QVariantList installedApps() const { return m_installedApps; }
    Q_INVOKABLE QVariantList hiddenApps() const;
    QVariantList drawerFolders() const { return m_drawerFolders; }

    Q_INVOKABLE bool launch(const QString& target, const QString& args = {});
    Q_INVOKABLE bool runAsDifferentUser(const QString& target, const QString& args = {});
    Q_INVOKABLE bool runElevated(const QString& target, const QString& args = {});
    Q_INVOKABLE bool revealInExplorer(const QString& target);
    Q_INVOKABLE bool openContainingFolder(const QString& target);
    Q_INVOKABLE bool openTargetFolder(const QString& target);
    Q_INVOKABLE void hideApp(const QString& target, const QString& name = {});
    Q_INVOKABLE void unhideApp(const QString& target);
    Q_INVOKABLE void clearHiddenApps();
    Q_INVOKABLE bool isHidden(const QString& target) const;
    Q_INVOKABLE QVariantMap inspectTarget(const QString& target) const;
    Q_INVOKABLE void recordUsage(const QString& target);
    Q_INVOKABLE QVariantList searchApps(const QString& query) const;
    Q_INVOKABLE QVariantList listPathSuggestions(const QString& rawPath) const;
    Q_INVOKABLE void refreshInstalledApps();
    Q_INVOKABLE void addPinnedApp(const QString& name, const QString& target,
                                  const QString& args = {});
    Q_INVOKABLE void removePinnedApp(int index);
    Q_INVOKABLE void removePinnedByTarget(const QString& target);
    Q_INVOKABLE void movePinnedApp(int fromIndex, int toIndex);
    Q_INVOKABLE void insertSeparatorAt(int index);
    Q_INVOKABLE void pinAppAt(const QString& name, const QString& target,
                              const QString& args, int index);
    Q_INVOKABLE void reorderDock(const QVariantList& currentAppItems,
                                 int fromIndex, int toIndex);
    Q_INVOKABLE int pinDroppedFiles(const QStringList& paths);
    Q_INVOKABLE bool addCustomApp(const QString& path);
    Q_INVOKABLE void removeCustomApp(const QString& target);
    Q_INVOKABLE QString createFolder(const QString& name, const QString& targetA,
                                     const QString& targetB);
    Q_INVOKABLE QString createFolderMulti(const QString& name, const QStringList& targets);
    Q_INVOKABLE void hideApps(const QVariantList& items);
    Q_INVOKABLE void addAppToFolder(const QString& folderId, const QString& target);
    Q_INVOKABLE void addAppsToFolder(const QString& folderId, const QStringList& targets);
    Q_INVOKABLE void removeAppFromFolder(const QString& folderId, const QString& target);
    Q_INVOKABLE void renameFolder(const QString& folderId, const QString& newName);
    Q_INVOKABLE void deleteFolder(const QString& folderId);
    Q_INVOKABLE void reload();

signals:
    void pinnedAppsChanged();
    void installedAppsChanged();
    void hiddenAppsChanged();
    void drawerFoldersChanged();

private:
    void seedDefaultsIfEmpty();
    void savePinnedApps();
    void saveHiddenApps();
    void saveCustomApps();
    void saveDrawerFolders();
    bool stripTargetFromFolders(const QString& normTarget, const QString& keepFolderId = {});

    SettingsStore* m_settings = nullptr;
    QVariantList m_pinnedApps;
    QVariantList m_installedApps;
    QVariantList m_customApps;
    QVariantList m_drawerFolders;
    QVariantMap m_usageCounts;
    QVariantMap m_hiddenApps;
};
