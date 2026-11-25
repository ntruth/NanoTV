import Foundation

/// 「值得重看」的数据入口：按当前范围取出旧照片，并整理成人物 / 地点 / 场景 / 年份主体。
extension LibraryStore {
    /// 当前范围里「值得重看」的照片。
    var revisitScopePhotos: [PhotoItem] {
        if isCloudScope { return cloudRevisitPhotos }
        if isSystemScope {
            return photos(for: .systemRevisit)
        }
        return revisitPhotos
    }

    func revisitInsight(onlyUnseen: Bool) -> RevisitInsight {
        let source = revisitScopePhotos
        let filtered = onlyUnseen ? source.filter { $0.viewedAt == nil } : source
        let analysis = isCloudScope
            ? cloudModel.analysis
            : (isSystemScope ? systemAnalysisIndex : analysisIndex)

        var seeds: [RevisitPersonSeed] = []
        if isCloudScope {
            seeds = cloudPeople.compactMap { person in
                guard !person.assetIDs.isEmpty else { return nil }
                return RevisitPersonSeed(id: "cloud-\(person.id.uuidString)",
                                         name: person.name,
                                         assetIDs: person.assetIDs,
                                         coverPhotoID: person.assetIDs.first,
                                         coverData: person.coverImageData)
            }
        } else if isSystemScope {
            seeds = systemPeople.compactMap { person in
                guard !person.assetIDs.isEmpty else { return nil }
                return RevisitPersonSeed(id: "system-\(person.id)",
                                         name: person.name,
                                         assetIDs: person.assetIDs,
                                         coverPhotoID: person.keyAssetID ?? person.assetIDs.first,
                                         coverData: person.cropData)
            }
        } else {
            loadFaceDataIfNeeded()
            seeds = localPeople.map { person in
                RevisitPersonSeed(id: person.id.uuidString,
                                  name: person.name,
                                  assetIDs: person.assetIDs,
                                  coverPhotoID: person.assetIDs.first,
                                  coverData: person.coverImageData)
            }
        }

        return RevisitInsight.make(photos: filtered,
                                   onlyUnseen: onlyUnseen,
                                   people: seeds,
                                   analysis: analysis)
    }
}
