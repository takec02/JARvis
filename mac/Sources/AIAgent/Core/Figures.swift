import Foundation

/// 名前の候補にする日本の偉人。エージェントは「仕える側」なので、軍師・側近・忍びなど補佐役の人物を選んでいる。
/// 呼びかけに使うため、日常語と同じ読みになる人物（例: 天海＝展開、利休≒リキュール）は外している。
struct HistoricalFigure: Identifiable, Hashable {
    let name: String      // 呼び名（カタカナ）。そのままウェイクワードになる
    let fullName: String  // 漢字の氏名
    let note: String      // ひとこと紹介
    var id: String { name }

    static let all: [HistoricalFigure] = [
        // 軍師・参謀
        .init(name: "ハンベエ", fullName: "竹中半兵衛", note: "秀吉の天才軍師"),
        .init(name: "カンベエ", fullName: "黒田官兵衛", note: "秀吉の名参謀"),
        .init(name: "カンスケ", fullName: "山本勘助", note: "武田の軍師"),
        .init(name: "マサノブ", fullName: "本多正信", note: "家康の懐刀"),
        .init(name: "コジュウロウ", fullName: "片倉小十郎", note: "政宗の右腕"),
        .init(name: "カネツグ", fullName: "直江兼続", note: "上杉の名家老"),
        // 側近・右腕
        .init(name: "ヒデナガ", fullName: "豊臣秀長", note: "天下一の補佐役"),
        .init(name: "ミツナリ", fullName: "石田三成", note: "秀吉の側近"),
        .init(name: "サコン", fullName: "島左近", note: "三成の右腕"),
        .init(name: "ヨシツグ", fullName: "大谷吉継", note: "三成の盟友"),
        .init(name: "ランマル", fullName: "森蘭丸", note: "信長の小姓"),
        .init(name: "ベンケイ", fullName: "武蔵坊弁慶", note: "義経の忠臣"),
        .init(name: "クラノスケ", fullName: "大石内蔵助", note: "赤穂の家老"),
        // 忍び
        .init(name: "ハンゾウ", fullName: "服部半蔵", note: "家康に仕えた忍び"),
        .init(name: "サスケ", fullName: "猿飛佐助", note: "真田の忍び"),
        // 教養・技術
        .init(name: "シキブ", fullName: "紫式部", note: "宮仕えの才女"),
        .init(name: "マンジロウ", fullName: "ジョン万次郎", note: "通訳・国際人"),
        .init(name: "ゲンナイ", fullName: "平賀源内", note: "発明家"),
    ]
}
