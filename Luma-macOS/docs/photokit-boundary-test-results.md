# PhotoKit 边界本机测试结果

**测试日期：2026-11-19**

## 1. 测试环境

| 项目 | 结果 |
| --- | --- |
| 系统 | macOS 27.0.1（26A434） |
| 应用 | 拾光 Luma 1.1，`com.baymax.luma` |
| 图库 | 本机系统「照片」图库 |
| 照片权限 | `authorized`（读写） |
| 测试开始时图库规模 | 1,702 个资产、26 个用户相簿、23 个文件夹 |
| 测试资产 | 仅 `LumaPhotoKitProbe-*` 前缀的临时图片 |

### 1.1 测试方式

- 通过临时注入 Luma.app 进程的测试 dylib 调用 PhotoKit。
- 只创建、修改、删除 `LumaPhotoKitProbe-*` 测试资产。
- 没有修改任何已有用户照片。
- 没有写入 Apple `Photos.sqlite`；只在测试后用只读 SQL 查询字段值做交叉验证。

> 说明：早期把测试放在 dylib 构造函数里执行时，`PHImageManager` 和 `requestContentEditingInput` 返回 nil；把测试延后到应用主循环启动后执行，两者都正常。这说明早期的 nil 是测试时机问题，不是 PhotoKit 能力缺失。

---

## 2. 严格结论

### 2.1 可以正常做

| 操作 | API | 本机结果 |
| --- | --- | --- |
| 读取资产总数 | `PHAsset fetchAssetsWithOptions:` | 1,702，正常 |
| 读取用户相簿 | `PHAssetCollection fetchAssetCollectionsWithType:` | 26，正常 |
| 读取用户文件夹 | `PHCollectionList fetchCollectionListsWithType:` | 23，正常 |
| 导入资产 | `PHAssetCreationRequest` + `addResourceWithType:` | 成功，导入 2 个资产并可查询到 |
| 收藏 / 取消收藏 | `PHAssetChangeRequest.favorite` | 设为 true 后验证为 true，恢复成功 |
| 修改拍摄日期 | `PHAssetChangeRequest.creationDate` | 设为 2020-09-13 12:26:40，验证成功，恢复成功 |
| 修改坐标 | `PHAssetChangeRequest.location` | 设为 37.3327,-122.0053，验证成功，恢复成功 |
| 编辑照片内容 | `PHContentEditingInput` + `PHContentEditingOutput` | 成功写回，`hasAdjustments=1` |
| 还原原图 | `revertAssetContentToOriginal` | 成功，`hasAdjustments=0` |
| 新建相簿 | `PHAssetCollectionChangeRequest.creationRequestForAssetCollectionWithTitle:` | 成功，可查询到 |
| 重命名相簿 | `PHAssetCollectionChangeRequest.title` | 成功，标题验证正确 |
| 删除相簿 | `deleteAssetCollections:` | 成功，查询不到 |
| 相簿加照片 | `addAssets:` | 成功，数量从 0 变 2 |
| 相簿移出照片 | `removeAssets:` | 成功，数量从 2 变 1 |
| 相簿内排序 | `moveAssetsAtIndexes:toIndex:` | 成功，首位资产变化 |
| 新建文件夹 | `PHCollectionListChangeRequest.creationRequestForCollectionListWithTitle:` | 成功，可查询到 |
| 重命名文件夹 | `PHCollectionListChangeRequest.title` | 成功，标题验证正确 |
| 文件夹加入子相簿 | `addChildCollections:` | 成功，子集合数量为 1 |
| 文件夹移出子相簿 | `removeChildCollections:` | 成功 |
| 删除文件夹 | `deleteCollectionLists:` | 成功，查询不到 |
| 监听外部变更 | `PHPhotoLibraryChangeObserver` | 收藏变更后回调触发 |
| 读取原图资源 | `PHAssetResourceManager` | 导出成功，文件大小 791 字节 |
| 读取图片/缩略图 | `PHImageManager` | 成功返回图片，`IsDegraded=0` |
| 删除测试资产 | `PHAssetChangeRequest.deleteAssets:` | 成功，删除后查询数量为 0 |

### 2.2 能做但有严重副作用

| 操作 | API | 本机结果 |
| --- | --- | --- |
| 隐藏资产 | `PHAssetChangeRequest.hidden` | `performChanges` 返回成功，`Photos.sqlite` 中 `ZASSET.ZHIDDEN=1` |

**但隐藏后出现了严格边界：**

- `fetchAssetsWithLocalIdentifiers:` 查不到该资产。
- `fetchAssetsWithOptions:` 加 `includeHiddenAssets=YES` 也查不到。
- 「已隐藏」智能相簿查询数量为 0。
- `NSPredicate` 使用 `hidden == YES` 查询数量为 0。
- 因此，**在本次 macOS 27.0.1 环境中，PhotoKit 把资产隐藏后就无法再通过 PhotoKit 取回、取消隐藏或删除它**。
- 只能在系统「照片」App 的「已隐藏」里手动恢复/删除。

> 这是本次测试最重要的风险。产品如果对 native 资产使用 PhotoKit 隐藏，必须保证用户能在「照片」里操作，并且不能承诺“在拾光里取消隐藏”。否则建议改用 Luma 本地隐藏字段，不写 PhotoKit。

### 2.3 不能做

| 操作 | 结果 | 原因 |
| --- | --- | --- |
| 设置标题 | ❌ 无 API | PhotoKit 不提供标题写接口 |
| 添加 / 移除关键词 | ❌ 无 API | PhotoKit 不提供关键词写接口 |
| 设置相簿封面 / 关键照片 | ❌ 无 API | PhotoKit 不提供 key asset 写接口 |
| 创建 / 编辑智能相簿 | ❌ 无 API | 智能相簿由 Photos 规则生成 |
| 永久删除 | ❌ 无 API | `deleteAssets` 只能移入「最近删除」 |
| 清空最近删除 | ❌ 无 API | 没有永久删除接口 |
| 从最近删除恢复 | ❌ 无 API | 没有恢复接口 |
| 人物命名 / 合并 | ❌ 无 API | PhotoKit 不提供人物写接口 |
| 重复项目合并 | ❌ 无 API | 没有公开合并接口 |

---

## 3. 关键日志

### 3.1 导入、收藏、日期、坐标、监听、相簿、文件夹

```text
AUTH_INITIAL=authorized
AUTH_FINAL=authorized
READ_ALL_ASSETS=1702
READ_USER_ALBUMS=26
READ_USER_FOLDERS=23

IMPORT_ASSETS=OK
IMPORT_VERIFY_COUNT=2
IMPORTED_ASSET1=OK
IMPORTED_ASSET2=OK

FAVORITE_SET_TRUE=OK
FAVORITE_VERIFY_TRUE=1
FAVORITE_RESTORE=OK

HIDDEN_SET_TRUE=OK
HIDDEN_FETCH_AFTER=0
HIDDEN_OBJECT_FLAG_AFTER=0
HIDDEN_RESTORE=OK
HIDDEN_RESTORED_FETCH=1

CREATION_DATE_SET=OK
CREATION_DATE_VERIFY=1 actual=2020-09-13 12:26:40 +0000
CREATION_DATE_RESTORE=OK

LOCATION_SET=OK
LOCATION_VERIFY=1 actual=37.332700,-122.005300
LOCATION_RESTORE=OK

CHANGE_OBSERVER_TRIGGER=OK
CHANGE_OBSERVER_FIRED=1
CHANGE_OBSERVER_RESTORE=OK

ALBUM_CREATE=OK
ALBUM_CREATE_VERIFY=1
ALBUM_RENAME=OK
ALBUM_RENAME_VERIFY=LumaPhotoKitProbe Album Renamed
ALBUM_ADD_ASSETS=OK
ALBUM_COUNT_AFTER_ADD=2
ALBUM_REORDER=OK
ALBUM_REORDER_VERIFY=1
ALBUM_REMOVE_ASSET=OK
ALBUM_COUNT_AFTER_REMOVE=1
ALBUM_DELETE=OK
ALBUM_DELETE_VERIFY=1

FOLDER_CREATE=OK
FOLDER_CREATE_VERIFY=1
FOLDER_RENAME=OK
FOLDER_RENAME_VERIFY=LumaPhotoKitProbe Folder Renamed
FOLDER_ADD_CHILD=OK
FOLDER_CHILD_COUNT=1
FOLDER_REMOVE_CHILD=OK
FOLDER_DELETE=OK
FOLDER_DELETE_VERIFY=1
```

### 3.2 编辑与图片读取（应用主循环启动后）

```text
IMPORT_EDIT_ASSET=OK
CAN_CONTENT=1
CAN_PROPERTIES=1
RESOURCE type=1 filename=LumaPhotoKitProbe-CDB50296-edit.jpg

EDIT_INPUT=OK info={ PHImageResultRequestIDKey = 1; }
INPUT_MEDIA_TYPE=1
fullSizeImageURL=file:///.../originals/1/149042BE-521F-4428-B186-C092E9088B21.jpeg
fullSizeImageOrientation=1

OUTPUT=OK renderedContentURL=file:///.../render.1B9712B8-6AC2-4B35-9E95-93960DA1E99F.JPG
OUTPUT_WRITE=1 error=none
EDIT_WRITE=OK
AFTER_EDIT_FETCH=OK hasAdjustments=1
EDIT_REVERT=OK
AFTER_REVERT_FETCH=OK hasAdjustments=0

IMAGE_MANAGER=OK info={ PHImageResultIsDegradedKey = 0; PHImageResultRequestIDKey = 2; }
DELETE_EDIT_ASSET=OK
RESULT=DONE
```

### 3.3 隐藏后的只读数据库交叉验证

对隐藏测试资产执行只读 SQL：

```sql
SELECT a.ZUUID, aa.ZORIGINALFILENAME, a.ZTRASHEDSTATE, a.ZHIDDEN
FROM ZASSET a
LEFT JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
WHERE aa.ZORIGINALFILENAME LIKE 'LumaPhotoKitProbe-%' AND a.ZTRASHEDSTATE = 0;
```

结果：

```text
91EC5932-194E-444E-BD2B-A97508446A20|LumaPhotoKitProbe-A13298EC-a.jpg|0|1
F59D0400-20DD-469B-92CE-FF6681EC5E2B|LumaPhotoKitProbe-A3D38978-a.jpg|0|1
4DBDA691-EFCE-43C6-8B65-D9C23396DB91|LumaPhotoKitProbe-A6ECA8C5-a.jpg|0|1
```

说明：

- `ZTRASHEDSTATE=0`：没有进最近删除。
- `ZHIDDEN=1`：确实被标记为隐藏。
- 但 PhotoKit 已经查不到它们。

---

## 4. 对产品方案的影响

### 4.1 可以直接依赖 PhotoKit

- 导入。
- 收藏 / 取消收藏。
- 修改拍摄日期、坐标。
- 编辑照片内容并还原。
- 相簿增删改、成员增删、排序。
- 文件夹增删改、子相簿增删。
- 删除到「最近删除」。
- 外部变更监听。
- 原图 / 缩略图读取。

### 4.2 必须保留 Luma SQLite 覆盖层

- 标题。
- 关键词。
- 查看时间。
- 智能相簿。
- 相簿封面。
- 人物命名 / 合并 / 封面。
- 重复项目合并。
- 最近删除恢复 / 永久删除（native 不可实现）。

### 4.3 需要产品重新决策

**隐藏照片。**

本次实测表明，PhotoKit 隐藏后资产会从 PhotoKit 查询中消失，且没有公开 API 取消隐藏。建议二选一：

1. **不要对 native 资产调用 PhotoKit `hidden`**，隐藏只写 Luma `luma_assets.hidden`，保证 Luma 内可恢复；Apple「照片」中不隐藏。
2. 仍然写 PhotoKit 隐藏，但在 UI 明确提示“已隐藏到系统照片，恢复请到「照片」App 的已隐藏相簿”，并且 Luma 不提供取消隐藏入口。

当前代码走的是第 2 条路径（`setSystemHidden` 调用 PhotoKit），需要产品确认是否接受这个限制。

---

## 5. 测试遗留物

本次测试只操作 `LumaPhotoKitProbe-*` 测试资产，但目前仍有测试图片留在系统图库：

- **3 张隐藏测试图**（未进最近删除，PhotoKit 已无法取回）：
  - `LumaPhotoKitProbe-A13298EC-a.jpg`
  - `LumaPhotoKitProbe-A3D38978-a.jpg`
  - `LumaPhotoKitProbe-A6ECA8C5-a.jpg`
- **9 张已在「最近删除」的测试图**：可在「照片 › 最近删除」中清空。
- 处理方式：打开「照片」App → 侧边栏「已隐藏」→ 选中上述 3 张 → 删除；再到「最近删除」清空测试图。
- 本次没有写入 Apple `Photos.sqlite`；隐藏测试图只能通过 Photos App 手动清理。

---

## 6. 复现方式

测试代码在 `/tmp/luma_photokit_probe/`：

| 文件 | 用途 |
| --- | --- |
| `probe_full.m` | 全量测试：导入、收藏、隐藏、日期、坐标、监听、相簿、文件夹、资源、图片、删除 |
| `probe_edit_only.m` | 编辑与图片读取专项测试（应用主循环启动后执行） |
| `probe_cleanup.m` | 清理测试资产、测试相簿、测试文件夹 |

运行方式：

```sh
open -W -n \
  --env DYLD_INSERT_LIBRARIES=/tmp/luma_photokit_probe/probe_full.dylib \
  -o /tmp/luma_probe_out.txt \
  --stderr /tmp/luma_probe_err.txt \
  /Users/lijialong/Documents/gitlab/photos/Luma.app
```

原始日志：

- `/tmp/luma_photokit_probe/results.txt`
- `/tmp/luma_photokit_probe/results_edit.txt`
- `/tmp/luma_photokit_probe/results_cleanup.txt`
