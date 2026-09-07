import Foundation
import Domain

/// Designer fixtures only. Never persisted as owned games or compatibility evidence.
enum PreviewCatalog {
    static let games: [Game] = {
        let records: [(Int, String, InstallStatus, Int, String, [String])] = [
            (1145360,"Hades",.installed,31,"15.2 GB",["Action","Roguelike","Singleplayer"]),
            (268910,"Cuphead",.installed,6,"4.0 GB",["Action","Platformer","Couch co-op"]),
            (367520,"Hollow Knight",.installed,22,"9.0 GB",["Action","Adventure","Metroidvania"]),
            (588650,"Dead Cells",.installed,9,"2.1 GB",["Action","Roguelike","Platformer"]),
            (413150,"Stardew Valley",.installed,48,"628 MB",["Simulation","RPG","Couch co-op"]),
            (646570,"Slay the Spire",.installed,14,"1.0 GB",["Strategy","Roguelike","Card game"]),
            (504230,"Celeste",.queued,0,"1.2 GB",["Platformer","Indie","Singleplayer"]),
            (753640,"Outer Wilds",.notInstalled,0,"8.0 GB",["Adventure","Exploration","Singleplayer"]),
            (553420,"TUNIC",.downloading,0,"8.9 GB",["Action","Adventure","Isometric","Singleplayer"]),
            (1055540,"A Short Hike",.installed,4,"400 MB",["Adventure","Exploration","Indie"]),
            (736260,"Baba Is You",.installed,2,"200 MB",["Puzzle","Indie","Singleplayer"]),
            (204360,"Castle Crashers",.driveDisconnected,0,"255 MB",["Action","Couch co-op"]),
            (632470,"Disco Elysium",.notInstalled,0,"22 GB",["RPG","Adventure","Singleplayer"]),
            (1092790,"Inscryption",.installed,3,"3.0 GB",["Card game","Horror","Singleplayer"]),
            (590380,"Into the Breach",.installed,7,"300 MB",["Strategy","Roguelike"]),
            (460950,"Katana ZERO",.installed,1,"200 MB",["Action","Platformer"]),
            (1057090,"Ori and the Will of the Wisps",.notInstalled,0,"9.6 GB",["Adventure","Platformer"]),
            (728880,"Overcooked! 2",.notInstalled,0,"3.0 GB",["Couch co-op","Simulation"]),
            (653530,"Return of the Obra Dinn",.installed,5,"2.0 GB",["Puzzle","Adventure"]),
            (972660,"Spiritfarer",.notInstalled,0,"7.0 GB",["Adventure","Simulation"]),
            (105600,"Terraria",.notInstalled,0,"200 MB",["Adventure","Sandbox","Couch co-op"]),
            (251470,"TowerFall Ascension",.installed,2,"400 MB",["Action","Couch co-op"]),
            (391540,"Undertale",.installed,6,"200 MB",["RPG","Indie"]),
        ]
        let descriptions = [
            "Hades": "Defy the god of the dead as you battle out of the Underworld in this rogue-like dungeon crawler from the creators of Bastion and Transistor.",
            "TUNIC": "Explore a land of ruins and secrets as a small fox, piecing together an in-game manual one page at a time.",
            "Cuphead": "A classic run and gun action game heavily focused on boss battles. Explore strange worlds, learn powerful super moves, and discover hidden secrets.",
            "A Short Hike": "Hike, climb, and soar through the peaceful mountainside landscapes of Hawk Peak Provincial Park. Follow the marked trails or explore the backcountry as you make your way to the summit.",
        ]
        return records.map { id, title, status, hours, size, genres in
            let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/"
            return Game(id: .init(source: "steam", value: String(id)), title: title, status: status,
                        hoursPlayed: hours, size: size,
                        summary: descriptions[title] ?? "Discover \(title). Game details will appear here when your library is connected.",
                        genres: genres, coverURL: URL(string: base + "library_600x900.jpg"),
                        heroURL: URL(string: base + "library_hero.jpg"), logoURL: URL(string: base + "logo.png"),
                        isFavorite: [1145360,632470,1057090,753640,391540].contains(id))
        }
    }()
}

extension PreviewCatalog {
    static let collections: [GameCollection] = [
        GameCollection(name: "Couch co-op", gameIDs: Set(games.filter { $0.genres.contains("Couch co-op") }.map(\.id)), isPinned: true),
        GameCollection(name: "Short sessions", gameIDs: Set(games.filter { $0.hoursPlayed > 0 && $0.hoursPlayed < 8 }.map(\.id))),
    ]
}
