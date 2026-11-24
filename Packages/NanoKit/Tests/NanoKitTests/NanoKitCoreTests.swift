import XCTest
@testable import NanoCore
@testable import NanoLiveTV
@testable import NanoMusic
@testable import NanoPlayerKit
@testable import NanoRemoteHub
@testable import NanoScraper
@testable import NanoVFS

final class NanoKitCoreTests: XCTestCase {
    // MARK: - 阶段一测试：外挂字幕解析、延迟偏移与 SQLite 播放历史读写

    func testExternalSRTAndASSSubtitleParsingWithDelay() {
        let srt = """
        1
        00:00:10,000 --> 00:00:14,500
        <i>第一句测试字幕</i>

        2
        00:00:16,000 --> 00:00:20,000
        第二句对白
        """
        let cues = ExternalSubtitleParser.parse(content: srt, fileExtension: "srt")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(ExternalSubtitleParser.activeSubtitleText(in: cues, at: 12.0), "第一句测试字幕")
        // 正向延迟 +2.0s 时，第 15 秒应命中原 13s 的第一句字幕
        XCTAssertEqual(ExternalSubtitleParser.activeSubtitleText(in: cues, at: 15.0, delaySec: 2.0), "第一句测试字幕")

        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:01:02.00,0:01:05.50,Default,,0,0,0,,{\\pos(400,570)}特效ASS字幕正文\\N第二行
        """
        let assCues = ExternalSubtitleParser.parse(content: ass, fileExtension: "ass")
        XCTAssertEqual(assCues.count, 1)
        XCTAssertEqual(assCues[0].text, "特效ASS字幕正文\n第二行")
    }

    func testSQLitePlaybackProgressPersistence() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("nano_test_\(UUID().uuidString).sqlite")
        let store = NanoDatabaseStore(customURL: tempURL)
        let rec = PlaybackProgressRecord(
            id: "test_video_key",
            vfsPath: "/Movies/Avatar.mkv",
            title: "Avatar",
            positionSec: 600,
            durationSec: 2400
        )
        try await store.upsert(namespace: "playback_history", id: rec.id, value: rec)
        let fetched = await store.fetchAll(namespace: "playback_history", as: PlaybackProgressRecord.self)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.percentage, 25)
    }

    // MARK: - 阶段二测试：文件名智能清洗与目录批量分集聚类刮削

    func testMediaFilenameSanitizerAndBatchDirectoryClustering() async {
        let parsed = MediaScraperEngine.parseFilename("[阳光电影]走马上任.S01E02.2026.2160p.WEB-DL.DV.HDR.60fps.mkv")
        XCTAssertEqual(parsed.cleanTitle, "走马上任")
        XCTAssertEqual(parsed.season, 1)
        XCTAssertEqual(parsed.episode, 2)
        XCTAssertEqual(parsed.year, 2026)
        XCTAssertEqual(parsed.spec.resolution, "4K")
        XCTAssertEqual(parsed.spec.dynamicRange, "Dolby Vision")
        XCTAssertEqual(parsed.spec.frameRate, "60 fps")

        let sourceID = UUID()
        let nodes = [
            VFSNode(sourceID: sourceID, fileID: "1", name: "走马上任.S01E01.2160p.HDR.mkv", path: "/TV/S01E01.mkv", kind: .video),
            VFSNode(sourceID: sourceID, fileID: "2", name: "走马上任.S01E02.2160p.HDR.mkv", path: "/TV/S01E02.mkv", kind: .video)
        ]
        let scraper = MediaScraperEngine(tmdbAPIKey: "")
        let results = await scraper.batchScrapeDirectoryNodes(nodes: nodes, sourceID: sourceID)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].item.kind, .tvSeries)
        XCTAssertEqual(results[0].episodes.count, 2)
        XCTAssertEqual(results[0].episodes[1].code, "S01E02")
    }

    // MARK: - 阶段三测试：IPTV 同名多线聚合、回看拼装与 XMLTV 节目单流式解析

    func testIPTVMultiLineAggregationAndXMLTVEPGParsing() {
        let sampleM3U = """
        #EXTM3U
        #EXTINF:-1 group-title="央视频道" catchup="append" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",CCTV-1 综合 HD
        http://192.168.1.2/cctv1_line1.m3u8
        #EXTINF:-1 group-title="央视",CCTV1 超高清
        http://192.168.1.2/cctv1_line2.m3u8
        """
        let groups = IPTVLiveEngine.parseAndAggregate(content: sampleM3U, subscriptionID: UUID())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].lines.count, 2)
        XCTAssertEqual(groups[0].category, "央视")
        XCTAssertTrue(groups[0].supportsCatchup)

        let sampleXMLTV = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch_cctv1">
            <display-name lang="zh">CCTV-1 综合</display-name>
          </channel>
          <programme start="20261124190000 +0800" stop="20261124193000 +0800" channel="ch_cctv1">
            <title lang="zh">新闻联播</title>
          </programme>
          <programme start="20261124193800 +0800" stop="20261124203000 +0800" channel="ch_cctv1">
            <title lang="zh">焦点访谈</title>
          </programme>
        </tv>
        """
        let epgMap = XMLTVEPGParser.parseXMLData(Data(sampleXMLTV.utf8))
        let stdKey = IPTVLiveEngine.normalizeChannelName("CCTV-1 综合")
        XCTAssertEqual(epgMap[stdKey]?.count, 2)
        XCTAssertEqual(epgMap[stdKey]?.first?.title, "新闻联播")
    }

    // MARK: - 远程源与无损 CUE 分轨测试

    func testFongMiAndCueSheetParsing() throws {
        let fongMiJSON = """
        {
          "sites": [
            { "key": "cms1", "name": "极光资源", "type": 1, "api": "https://example.com/api.php/provide/vod/", "searchable": 1 }
          ]
        }
        """
        let bundle = try RemoteResourceEngineHub.parseFongMiSubscriptionJSON(fongMiJSON)
        XCTAssertEqual(bundle.sites.count, 1)

        let cue = """
        PERFORMER "蔡琴"
        TITLE "民歌蔡琴"
        FILE "蔡琴-民歌蔡琴.flac" WAVE
          TRACK 01 AUDIO
            TITLE "被遗忘的时光"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "渡口"
            INDEX 01 03:45:00
        """
        let tracks = HiFiMusicEngine.parseCueSheet(cueText: cue, sourceID: UUID(), directoryPath: "/Music", totalAudioDurationSec: 600)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[1].startOffsetSec, 225, accuracy: 0.1)
    }

    // MARK: - 统一搜索地域别名映射与多维组合分类筛选测试

    func testUnifiedSearchProvinceAliasAndMultiFacetFilter() {
        // 验证搜「上海」能通过省份别名词典精准命中不含“上海”二字的「东方卫视」
        let dragonTV = IPTVChannelGroup(
            channelNumber: 70,
            standardName: "DRAGONTV",
            displayName: "东方卫视 4K",
            category: "卫视"
        )
        XCTAssertEqual(IPTVLiveEngine.inferProvince(from: dragonTV.displayName), "上海")
        XCTAssertTrue(IPTVLiveEngine.matchesSearch(channel: dragonTV, keyword: "上海"))

        // 验证多维组合分类筛选器（题材 + 地区 + 年份 + 4K Dolby Vision 规格）
        let movie = MediaItem(
            kind: .movie,
            title: "深空纪元",
            year: 2026,
            genres: ["科幻", "冒险"],
            country: "美国",
            spec: VideoTechnicalSpec(resolution: "4K", dynamicRange: "Dolby Vision", frameRate: "24 fps")
        )
        var filter = MediaCategoryFilterState()
        filter.genreFilter = "科幻"
        filter.regionFilter = "美国"
        filter.yearFilter = "2026"
        filter.qualityFilter = "Dolby Vision"
        XCTAssertTrue(filter.matches(movie))

        filter.regionFilter = "日本"
        XCTAssertFalse(filter.matches(movie))
    }

    // MARK: - 内置小雅免 Docker 配置文件生成与局域网子网前缀测试

    func testEmbeddedXiaoyaConfigFileGenerationAndSubnetParsing() throws {
        XCTAssertEqual(XiaoyaLanScanner.subnetPrefix(from: "192.168.31.88"), "192.168.31")
        XCTAssertNil(XiaoyaLanScanner.subnetPrefix(from: "fe80::1"))

        let manager = EmbeddedXiaoyaManager.shared
        manager.config.listenPort = 5678
        manager.config.aliyunRefreshToken = "0123456789abcdef0123456789abcdef"
        manager.config.tempTransferFolderID = "folder_demo_123"
        try manager.persistConfigAndWriteXiaoyaFiles()

        let mytokenPath = manager.dataDir.appendingPathComponent("mytoken.txt")
        let configJsonPath = manager.dataDir.appendingPathComponent("config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mytokenPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configJsonPath.path))

        let savedToken = try String(contentsOf: mytokenPath, encoding: .utf8)
        XCTAssertEqual(savedToken, "0123456789abcdef0123456789abcdef")
    }

    // MARK: - Infuse Pro 特性测试：在线字幕搜索下载与连接测速 4K 原盘评级

    func testInfuseProOnlineSubtitleDownloadAndSpeedVerdict() async throws {
        let candidates = await OnlineSubtitleSearchService.shared.searchSubtitles(query: "Interstellar")
        XCTAssertFalse(candidates.isEmpty)
        let localSubURL = try await OnlineSubtitleSearchService.shared.downloadSubtitleToLocal(candidates[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: localSubURL.path))

        let remuxReport = SpeedBenchmarkReport(sourceName: "115网盘", averageMbps: 125.0)
        XCTAssertTrue(remuxReport.qualityVerdict.contains("REMUX"))

        let slowReport = SpeedBenchmarkReport(sourceName: "慢速源", averageMbps: 8.5)
        XCTAssertTrue(slowReport.qualityVerdict.contains("受限"))
    }
}
