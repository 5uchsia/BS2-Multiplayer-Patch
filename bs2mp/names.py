import re

from . import marshal

tr = {
    "うさぎ": "Rabbit", "うさぎ騎士": "Rabbit Knight", "えび": "Shrimp", "かちかち山": "Kachi-Kachi Tanuki",
    "かに": "Crab", "からあげ": "Fried Chicken", "くらげ": "Jellyfish", "こうもり大群": "Bat Swarm",
    "ぞんび娼婦": "Zombie Harlot", "ちわわ": "Chihuahua", "にわとり": "Chicken", "ぬいぐるみ": "Plushie",
    "ねずみ魔法使い": "Mouse Wizard", "もこ": "Moko", "わに": "Crocodile", "アライグマ": "Raccoon",
    "アリス": "Alice", "アリス巨大": "Giant Alice", "イーディス_滞空": "Edith (hovering)",
    "イーディス_着陸": "Edith (landing)", "イーディス_飛行": "Edith (flying)", "エイリアン": "Alien",
    "エリザ": "Eliza", "エレファントマン": "Elephant Man", "カエル巨大": "Giant Frog", "カキ": "Oyster",
    "カニ": "Crab", "ガンマン": "Gunman", "ガーゴ": "Gargo", "ギロチン": "Guillotine", "ギロチン_": "Guillotine",
    "クジラ": "Whale", "グリズリー": "Grizzly", "シャンデリア": "Chandelier", "ゾンビ": "Zombie",
    "ダイナ": "Dinah", "ダークホール": "Dark Hole", "チェシャ": "Cheshire", "チェス": "Chess",
    "ドロシー": "Dorothy", "ハインリヒ": "Heinrich", "ハンプティ": "Humpty", "バッタ": "Grasshopper",
    "バニー": "Bunny", "ビースト": "Beast", "ビースト骨": "Beast Skeleton", "ピエロ": "Clown",
    "ピノッキオ": "Pinocchio", "ブッチャー": "Butcher", "ブラックウェル": "Blackwell", "ブループ": "Bloop",
    "プレゼント": "Present", "ベルマン": "Bellman", "ホテルエルマ": "Hotel Elma", "ホームズ": "Holmes",
    "ポロ": "Polo", "ミミック": "Mimic", "ムカデ": "Centipede", "メイベル": "Mabel", "ユニス": "Eunice",
    "ライデン": "Raiden", "ラスカル": "Rascal", "リンダメア": "Lindamea", "ロルド": "Rold",
    "三月ウサギ": "March Hare", "三騎士": "Three Knights", "主人公": "Protagonist",
    "亡者の壁": "Wall of Hollows", "人攫い": "Kidnapper", "刑史": "Warden", "呪木": "Cursed Tree",
    "学長": "Dean", "巨人": "Giant", "布琳蒂死 - 副本": "Brinty (dead)", "彼女": "Her",
    "振り子": "Pendulum", "時計": "Clock", "暗黒物質": "Dark Matter", "精神外科医": "Psychosurgeon",
    "蓄音機": "Gramophone", "触手": "Tentacle", "赤ん坊": "Baby", "足跡": "Footprints",
    "道化女": "Jester Woman", "釣竿": "Fishing Rod", "門": "Gate", "雪だる": "Snowman", "餓鬼": "Hungry Ghost",
    "首無し亡者": "Headless Hollow", "首無し": "Headless", "骨犬": "Bone Dog", "骸骨": "Skeleton",
    "骸骨ローブ": "Robed Skeleton", "骸骨擬態": "Skeleton Mimic", "魚": "Fish", "N幽灵车": "Ghost Car",
    "多萝西": "Dorothy", "强敌": "Strong Foe", "显示器": "Monitor", "血迹": "Bloodstain", "塞塔兹行走图": "Setaz",
    "多萝西晕倒": "Dorothy (fainted)", "多萝西食脑": "Dorothy (brain eating)",
    "小矮人地面尸体": "Dwarf Corpse (ground)", "小矮人尸体": "Dwarf Corpse", "布琳蒂": "Brinty",
    "布琳蒂魔兽化": "Brinty (beast)", "废镇敌人": "Ruined Town Foe", "格劳行走图": "Grau", "父亲": "Father",
    "桔子": "Tangerine", "宝开": "Open Chest", "がいこつ": "Skeleton", "きのこ": "Mushroom",
    "キノコ": "Mushroom", "くるまいす": "Wheelchair", "じんめん木": "Face Tree", "びっくりばこ": "Jack-in-the-box",
    "ぴえろ": "Clown", "アクマ": "Demon", "ウィンターベル": "Winterbell", "カイ": "Kai", "カラス": "Crow",
    "カルト": "Cultist", "グリフィ": "Griffy", "グリフォン": "Gryphon", "グール": "Ghoul", "ゴースト": "Ghost",
    "サヨナキドリ": "Nightingale", "ジキル": "Jekyll", "トゥイードルダム": "Tweedledum",
    "トゥイードルディー": "Tweedledee", "トーヴ": "Tove", "ナース": "Nurse", "バンスナ犠牲者": "Bandersnatch Victim",
    "ヒドラ": "Hydra", "ファラ": "Fara", "フロア": "Floor", "ペンギン": "Penguin", "ホテル": "Hotel",
    "ボロゴーヴ": "Borogove", "マーライオン": "Merlion", "モンスター": "Monster", "ランジェリーナ": "Langerina",
    "ラース": "Lars", "上半身": "Upper Body", "下半身": "Lower Body", "亡者": "Hollow", "人形": "Doll",
    "人間爆弾": "Human Bomb", "兎": "Rabbit", "冬魔導士": "Winter Mage", "妖精小": "Small Fairy",
    "学徒": "Student", "従者": "Attendant", "患者": "Patient", "扉": "Door", "手_女": "Woman's Hand",
    "揺れる風船": "Swaying Balloon", "明かり": "Light", "星蟲": "Star Worm", "本": "Book",
    "死体・血・サイン": "Corpse, Blood, Sign", "灯": "Lamp", "熊": "Bear", "犬死体": "Dog Corpse",
    "狩人": "Hunter", "猫ねこんだ": "Sleeping Cat", "獣人_r": "Beastman", "生首": "Severed Head",
    "甲冑": "Armor", "目": "Eye", "眠りネズミ": "Dormouse", "素体": "Mannequin", "紳士": "Gentleman",
    "虫": "Bug", "蛇人": "Snake Person", "蛇神": "Snake God", "蜘蛛": "Spider", "蟲": "Insect",
    "鐘女": "Bell Woman", "雪獣": "Snow Beast", "青ひげ": "Bluebeard", "馬": "Horse", "騎士": "Knight",
    "騎士倒れ": "Fallen Knight", "黄布": "Yellow Cloth",
    "塞塔兹": "Setaz", "幽灵列车长": "Ghost Train Conductor", "格劳": "Grau", "格林": "Grimm",
    "稻草人": "Scarecrow", "精锐敌人": "Elite Foe", "希莉娅": "Celia", "萝斯梅可": "Rose Fluffy",
    "あし": "Legs", "いぬ": "Dog", "ぐれーてる": "Gretel", "にわ": "Chicken", "ねこ": "Cat", "ねずみ": "Mouse",
    "はんす": "Hans", "ばにー": "Bunny", "ぱと": "Pato", "ぱんぷ": "Pumpkin", "ぶれーめん": "Bremen",
    "へんぜる": "Hansel", "ほし": "Star", "よろい": "Armor", "ろば": "Donkey", "アリス・ドール": "Alice Doll",
    "アリス・リデル": "Alice Liddell", "ウミガメ": "Mock Turtle", "カーナッキ": "Carnacki", "クティ": "Kuti",
    "ゲルダ": "Gerda", "シヨ": "Sho", "シロクマ": "Polar Bear", "シンド": "Sindo", "シヴーチ": "Sivuch",
    "シーシャ": "Shisha", "ジャバ": "Jabberwock", "ジャブ": "Jubjub", "チェシャ猫": "Cheshire Cat",
    "チワワ": "Chihuahua", "トゥダム": "Tweedledum", "トゥディ": "Tweedledee", "トゥ双子": "Tweedles",
    "ドド": "Dodo", "ノーデ": "Node", "ハン": "Hein", "バン": "Bandersnatch", "ビク": "Victoria", "ビル": "Bill",
    "ピーター": "Peter", "フローレンス": "Florence", "ブラ": "Blackwell", "プリ": "Prickett",
    "ホテルエリザ": "Hotel Eliza", "ホテルカタリナ": "Hotel Catalina", "ホテルグース": "Hotel Goose",
    "ホテルジャンヌ": "Hotel Jeanne", "ホテルドロシー": "Hotel Dorothy", "ホテル人魚": "Hotel Mermaid",
    "メアリー": "Mary", "ランジェ": "Langerina", "ロビン": "Robin", "ロリーナ": "Lorina", "三女": "Third Sister",
    "三月兎": "March Hare", "公爵夫人": "Margaret", "妹アリス": "Little Alice", "娘アリス": "Daughter Alice",
    "帽子屋": "Hatta", "影": "Shadow", "次女": "Second Sister", "母アリス": "Mother Alice", "眠り鼠": "Dormouse",
    "紅ずきん": "Red Hood", "長女": "Eldest Sister", "魔獣": "Beast", "？？？": "???",
    "EXジャガーノート": "EX Juggernaut", "こびと": "Dwarf", "カラミール": "Karamir", "ギガントボス": "Gigant Boss",
    "デュラハン": "Dullahan", "ヘルカイザー": "Hell Kaiser", "マッチ売りpng": "Match Girl", "巨大赤鬼": "Giant Red Ogre",
    "巨大青鬼": "Giant Blue Ogre", "裸の王様": "Naked King", "黒": "Black", "14遺体": "Corpse 14", "Yデーモン": "Y Demon",
    "エズワルド": "Ezwald", "オックス": "Ox", "ベリオール": "Beliol", "ヴィル": "Vil",
}

wide = str.maketrans("０１２３４５６７８９", "0123456789")
tail = re.compile(r"^(.*?)[\s_]*(?:\((\d+)\)|(\d+(?:-\d+)?))$")


def official(game_dir):
    out = {}
    try:
        from .data import root

        rows = marshal.loads((root(game_dir) / "Data" / "Actors.rvdata2").read_bytes())
    except Exception:
        return out
    for a in rows:
        if not a:
            continue
        c = str(a.attrs.get("@character_name") or "")
        n = str(a.attrs.get("@name") or "").strip()
        if c and n and c not in out and all(ord(x) < 128 for x in n):
            out[c] = n
    return out


def en(raw, off=None):
    off = off or {}
    s = raw.lstrip("$").translate(wide).strip()
    if raw in off and s not in tr:
        return off[raw]
    for c in "【】「」":
        s = s.replace(c, "")
    s = s.strip()
    if s in tr:
        return tr[s]
    if s.endswith("狂") and len(s) > 1:
        got = en(s[:-1], off)
        if got != s[:-1]:
            return "Mad " + got
    m = tail.match(s)
    if m and m.group(1).strip():
        b = m.group(1).strip()
        got = en(("$" if raw.startswith("$") else "") + b, off)
        if got != b:
            num = "(%s)" % m.group(2) if m.group(2) else m.group(3)
            return "%s %s" % (got, num)
    return s
