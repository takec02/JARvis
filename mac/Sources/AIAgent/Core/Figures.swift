import Foundation

/// 名前の候補にする日本の偉人。
/// 呼びかけに使うため、日常語と同じ読み（例: 謙信＝献身、信玄＝震源、海舟＝回収）の人物は外している。
struct HistoricalFigure: Identifiable, Hashable {
    let name: String      // 呼び名（カタカナ）。そのままウェイクワードになる
    let fullName: String  // 漢字の氏名
    let note: String      // ひとこと紹介
    var id: String { name }

    static let all: [HistoricalFigure] = [
        .init(name: "ゲンナイ", fullName: "平賀源内", note: "発明家・エレキテル"),
        .init(name: "ハンベエ", fullName: "竹中半兵衛", note: "天才軍師"),
        .init(name: "カンベエ", fullName: "黒田官兵衛", note: "天下の名参謀"),
        .init(name: "タダタカ", fullName: "伊能忠敬", note: "日本地図の測量"),
        .init(name: "ホクサイ", fullName: "葛飾北斎", note: "浮世絵師"),
        .init(name: "マンジロウ", fullName: "ジョン万次郎", note: "通訳・国際人"),
        .init(name: "ベンケイ", fullName: "武蔵坊弁慶", note: "忠義の豪傑"),
        .init(name: "ヒミコ", fullName: "卑弥呼", note: "邪馬台国の女王"),
        .init(name: "シキブ", fullName: "紫式部", note: "源氏物語の作者"),
        .init(name: "コマチ", fullName: "小野小町", note: "六歌仙の歌人"),
        .init(name: "ウメコ", fullName: "津田梅子", note: "女子教育の先駆者"),
        .init(name: "ソウセキ", fullName: "夏目漱石", note: "文豪"),
        .init(name: "ヒデヨ", fullName: "野口英世", note: "細菌学者"),
        .init(name: "ユキチ", fullName: "福沢諭吉", note: "慶應義塾の創設者"),
        .init(name: "ムサシ", fullName: "宮本武蔵", note: "二刀流の剣豪"),
        .init(name: "ヨシツネ", fullName: "源義経", note: "若き名将"),
        .init(name: "マサムネ", fullName: "伊達政宗", note: "独眼竜"),
        .init(name: "リョウマ", fullName: "坂本龍馬", note: "幕末の志士"),
        .init(name: "ノブナガ", fullName: "織田信長", note: "戦国の革新者"),
        .init(name: "ヒデヨシ", fullName: "豊臣秀吉", note: "天下人"),
        .init(name: "イエヤス", fullName: "徳川家康", note: "江戸幕府を開く"),
    ]
}
