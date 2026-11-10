const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Proto = enum { tcp, udp };

pub const Port = struct {
    host: u16,
    container: u16,
    proto: Proto = .tcp,
    /// The port a browser opens. The installer can move this one to a free port.
    web: bool = false,
};

pub const Vol = struct {
    /// Named volume suffix, or the parameter key when `param` is set.
    name: []const u8,
    path: []const u8,
    /// A folder on the host that the user picks, mounted into the container.
    param: bool = false,
    ro: bool = false,
};

pub const Svc = struct {
    name: []const u8,
    image: []const u8,
    ports: []const Port = &.{},
    env: []const []const u8 = &.{},
    vols: []const Vol = &.{},
    cmd: []const []const u8 = &.{},
    caps: []const []const u8 = &.{},
    extra_hosts: []const []const u8 = &.{},
};

pub const Param = struct {
    key: []const u8,
    label: []const u8,
    help: []const u8 = "",
    required: bool = false,
};

pub const Category = enum { media, files, network, automation, monitoring, productivity, development, ai };

pub const App = struct {
    id: []const u8,
    name: []const u8,
    category: Category,
    blurb: []const u8,
    svcs: []const Svc,
    params: []const Param = &.{},
    /// Runs on the host network (device discovery). Ports are then not published.
    host_net: bool = false,
    notes: []const u8 = "",
    /// Show the generated password once after install, with this label.
    secret_label: []const u8 = "",
    web_path: []const u8 = "",
};

const tz = "TZ=UTC";
const lsio_env = [_][]const u8{ "PUID=1000", "PGID=1000", tz };

pub const catalog = [_]App{
    .{
        .id = "jellyfin",
        .name = "Jellyfin",
        .category = .media,
        .blurb = "Stream your own movies, shows and music to any device.",
        .params = &.{.{ .key = "media", .label = "Media folder", .help = "Folder on this server that holds your movies and shows", .required = true }},
        .svcs = &.{.{
            .name = "app",
            .image = "jellyfin/jellyfin:latest",
            .ports = &.{.{ .host = 8096, .container = 8096, .web = true }},
            .vols = &.{
                .{ .name = "config", .path = "/config" },
                .{ .name = "cache", .path = "/cache" },
                .{ .name = "media", .path = "/media", .param = true, .ro = true },
            },
        }},
    },
    .{
        .id = "immich",
        .name = "Immich",
        .category = .media,
        .blurb = "Back up and browse your phone photos and videos. A self-hosted Google Photos.",
        .notes = "Runs four containers and needs about 4 GB of RAM. Versions move quickly; check the Immich release notes before updating.",
        .svcs = &.{
            .{
                .name = "db",
                .image = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0",
                .env = &.{ "POSTGRES_USER=postgres", "POSTGRES_PASSWORD={secret}", "POSTGRES_DB=immich", "POSTGRES_INITDB_ARGS=--data-checksums" },
                .vols = &.{.{ .name = "pgdata", .path = "/var/lib/postgresql/data" }},
            },
            .{ .name = "cache", .image = "docker.io/valkey/valkey:9" },
            .{
                .name = "ml",
                .image = "ghcr.io/immich-app/immich-machine-learning:release",
                .vols = &.{.{ .name = "model", .path = "/cache" }},
            },
            .{
                .name = "server",
                .image = "ghcr.io/immich-app/immich-server:release",
                .ports = &.{.{ .host = 2283, .container = 2283, .web = true }},
                .env = &.{ "DB_HOSTNAME={name:db}", "DB_USERNAME=postgres", "DB_PASSWORD={secret}", "DB_DATABASE_NAME=immich", "REDIS_HOSTNAME={name:cache}", "IMMICH_MACHINE_LEARNING_URL=http://{name:ml}:3003", tz },
                .vols = &.{.{ .name = "upload", .path = "/data" }},
            },
        },
    },
    .{
        .id = "nextcloud",
        .name = "Nextcloud",
        .category = .files,
        .blurb = "Your own cloud for files, calendar, contacts and notes.",
        .notes = "Uses the built-in SQLite database, fine for a household. Large installs should move to PostgreSQL.",
        .svcs = &.{.{
            .name = "app",
            .image = "nextcloud:stable",
            .ports = &.{.{ .host = 8082, .container = 80, .web = true }},
            .vols = &.{.{ .name = "html", .path = "/var/www/html" }},
        }},
    },
    .{
        .id = "vaultwarden",
        .name = "Vaultwarden",
        .category = .productivity,
        .blurb = "A light Bitwarden-compatible password manager server.",
        .notes = "Browsers only allow the vault over HTTPS. Put it behind TLS (see scripts/setup-tls.sh) before using it.",
        .svcs = &.{.{
            .name = "app",
            .image = "vaultwarden/server:latest",
            .ports = &.{.{ .host = 8083, .container = 80, .web = true }},
            .vols = &.{.{ .name = "data", .path = "/data" }},
        }},
    },
    .{
        .id = "homeassistant",
        .name = "Home Assistant",
        .category = .automation,
        .blurb = "Control and automate lights, sensors and other smart home devices.",
        .host_net = true,
        .notes = "Runs on the host network so it can find devices. Opens on port 8123.",
        .svcs = &.{.{
            .name = "app",
            .image = "ghcr.io/home-assistant/home-assistant:stable",
            .ports = &.{.{ .host = 8123, .container = 8123, .web = true }},
            .env = &.{tz},
            .vols = &.{.{ .name = "config", .path = "/config" }},
        }},
    },
    .{
        .id = "pihole",
        .name = "Pi-hole",
        .category = .network,
        .blurb = "Block ads and trackers for every device on your network.",
        .secret_label = "Web password",
        .notes = "Needs port 53. If something already uses it (often systemd-resolved) the install will fail with a port error.",
        .web_path = "/admin",
        .svcs = &.{.{
            .name = "app",
            .image = "pihole/pihole:latest",
            .ports = &.{
                .{ .host = 8084, .container = 80, .web = true },
                .{ .host = 53, .container = 53 },
                .{ .host = 53, .container = 53, .proto = .udp },
            },
            .env = &.{ "FTLCONF_webserver_api_password={secret}", tz },
            .vols = &.{.{ .name = "etc", .path = "/etc/pihole" }},
        }},
    },
    .{
        .id = "adguardhome",
        .name = "AdGuard Home",
        .category = .network,
        .blurb = "Network-wide ad blocking and DNS with a friendly setup wizard.",
        .notes = "Needs port 53, so it cannot run next to Pi-hole. Finish setup in the wizard on first open.",
        .svcs = &.{.{
            .name = "app",
            .image = "adguard/adguardhome:latest",
            .ports = &.{
                .{ .host = 3000, .container = 3000, .web = true },
                .{ .host = 53, .container = 53 },
                .{ .host = 53, .container = 53, .proto = .udp },
            },
            .vols = &.{
                .{ .name = "work", .path = "/opt/adguardhome/work" },
                .{ .name = "conf", .path = "/opt/adguardhome/conf" },
            },
        }},
    },
    .{
        .id = "uptimekuma",
        .name = "Uptime Kuma",
        .category = .monitoring,
        .blurb = "Watch your websites and services and tell you when one goes down.",
        .svcs = &.{.{
            .name = "app",
            .image = "louislam/uptime-kuma:1",
            .ports = &.{.{ .host = 3001, .container = 3001, .web = true }},
            .vols = &.{.{ .name = "data", .path = "/app/data" }},
        }},
    },
    .{
        .id = "paperless",
        .name = "Paperless-ngx",
        .category = .files,
        .blurb = "Scan, index and search all your paper documents.",
        .params = &.{.{ .key = "consume", .label = "Inbox folder (optional)", .help = "Files dropped here are imported automatically" }},
        .notes = "Create the first user after install with: docker exec -it nodos-paperless-web createsuperuser",
        .svcs = &.{
            .{
                .name = "db",
                .image = "postgres:16",
                .env = &.{ "POSTGRES_DB=paperless", "POSTGRES_USER=paperless", "POSTGRES_PASSWORD={secret}" },
                .vols = &.{.{ .name = "pgdata", .path = "/var/lib/postgresql/data" }},
            },
            .{ .name = "broker", .image = "redis:7" },
            .{
                .name = "web",
                .image = "ghcr.io/paperless-ngx/paperless-ngx:latest",
                .ports = &.{.{ .host = 8000, .container = 8000, .web = true }},
                .env = &.{ "PAPERLESS_REDIS=redis://{name:broker}:6379", "PAPERLESS_DBHOST={name:db}", "PAPERLESS_DBPASS={secret}", "PAPERLESS_SECRET_KEY={secret2}", "PAPERLESS_TIME_ZONE=UTC" },
                .vols = &.{
                    .{ .name = "data", .path = "/usr/src/paperless/data" },
                    .{ .name = "media", .path = "/usr/src/paperless/media" },
                    .{ .name = "consume", .path = "/usr/src/paperless/consume", .param = true },
                },
            },
        },
    },
    .{
        .id = "navidrome",
        .name = "Navidrome",
        .category = .media,
        .blurb = "Your music collection as a streaming server, with apps for every phone.",
        .params = &.{.{ .key = "music", .label = "Music folder", .help = "Folder on this server that holds your music", .required = true }},
        .svcs = &.{.{
            .name = "app",
            .image = "deluan/navidrome:latest",
            .ports = &.{.{ .host = 4533, .container = 4533, .web = true }},
            .env = &.{"ND_LOGLEVEL=info"},
            .vols = &.{
                .{ .name = "data", .path = "/data" },
                .{ .name = "music", .path = "/music", .param = true, .ro = true },
            },
        }},
    },
    .{
        .id = "audiobookshelf",
        .name = "Audiobookshelf",
        .category = .media,
        .blurb = "Audiobooks and podcasts with progress synced across devices.",
        .params = &.{.{ .key = "audiobooks", .label = "Audiobook folder", .help = "Folder on this server that holds your audiobooks", .required = true }},
        .svcs = &.{.{
            .name = "app",
            .image = "ghcr.io/advplyr/audiobookshelf:latest",
            .ports = &.{.{ .host = 13378, .container = 80, .web = true }},
            .vols = &.{
                .{ .name = "config", .path = "/config" },
                .{ .name = "metadata", .path = "/metadata" },
                .{ .name = "audiobooks", .path = "/audiobooks", .param = true },
            },
        }},
    },
    .{
        .id = "sonarr",
        .name = "Sonarr",
        .category = .media,
        .blurb = "Keeps your TV library organized and up to date.",
        .params = &.{.{ .key = "tv", .label = "TV folder", .help = "Where your shows live", .required = true }},
        .svcs = &.{.{
            .name = "app",
            .image = "lscr.io/linuxserver/sonarr:latest",
            .ports = &.{.{ .host = 8989, .container = 8989, .web = true }},
            .env = &lsio_env,
            .vols = &.{
                .{ .name = "config", .path = "/config" },
                .{ .name = "tv", .path = "/tv", .param = true },
            },
        }},
    },
    .{
        .id = "radarr",
        .name = "Radarr",
        .category = .media,
        .blurb = "Keeps your movie library organized and up to date.",
        .params = &.{.{ .key = "movies", .label = "Movies folder", .help = "Where your movies live", .required = true }},
        .svcs = &.{.{
            .name = "app",
            .image = "lscr.io/linuxserver/radarr:latest",
            .ports = &.{.{ .host = 7878, .container = 7878, .web = true }},
            .env = &lsio_env,
            .vols = &.{
                .{ .name = "config", .path = "/config" },
                .{ .name = "movies", .path = "/movies", .param = true },
            },
        }},
    },
    .{
        .id = "prowlarr",
        .name = "Prowlarr",
        .category = .media,
        .blurb = "One place to manage the indexers that Sonarr and Radarr search.",
        .svcs = &.{.{
            .name = "app",
            .image = "lscr.io/linuxserver/prowlarr:latest",
            .ports = &.{.{ .host = 9696, .container = 9696, .web = true }},
            .env = &lsio_env,
            .vols = &.{.{ .name = "config", .path = "/config" }},
        }},
    },
    .{
        .id = "qbittorrent",
        .name = "qBittorrent",
        .category = .media,
        .blurb = "A torrent client with a web interface.",
        .params = &.{.{ .key = "downloads", .label = "Downloads folder", .help = "Where finished downloads are saved", .required = true }},
        .notes = "The first login is admin with a temporary password printed in the container log (Logs button on the Docker page).",
        .svcs = &.{.{
            .name = "app",
            .image = "lscr.io/linuxserver/qbittorrent:latest",
            .ports = &.{
                .{ .host = 8086, .container = 8086, .web = true },
                .{ .host = 6881, .container = 6881 },
                .{ .host = 6881, .container = 6881, .proto = .udp },
            },
            .env = &.{ "PUID=1000", "PGID=1000", tz, "WEBUI_PORT=8086" },
            .vols = &.{
                .{ .name = "config", .path = "/config" },
                .{ .name = "downloads", .path = "/downloads", .param = true },
            },
        }},
    },
    .{
        .id = "nginxproxymanager",
        .name = "Nginx Proxy Manager",
        .category = .network,
        .blurb = "Put names and free HTTPS certificates in front of your apps, with a web UI.",
        .notes = "Takes ports 80 and 443. Default login is admin@example.com with password changeme; change it at once.",
        .svcs = &.{.{
            .name = "app",
            .image = "jc21/nginx-proxy-manager:latest",
            .ports = &.{
                .{ .host = 81, .container = 81, .web = true },
                .{ .host = 80, .container = 80 },
                .{ .host = 443, .container = 443 },
            },
            .vols = &.{
                .{ .name = "data", .path = "/data" },
                .{ .name = "letsencrypt", .path = "/etc/letsencrypt" },
            },
        }},
    },
    .{
        .id = "syncthing",
        .name = "Syncthing",
        .category = .files,
        .blurb = "Keep folders in sync between your devices, with no cloud in the middle.",
        .params = &.{.{ .key = "sync", .label = "Folder to sync", .help = "Folder on this server to share", .required = true }},
        .svcs = &.{.{
            .name = "app",
            .image = "syncthing/syncthing:latest",
            .ports = &.{
                .{ .host = 8384, .container = 8384, .web = true },
                .{ .host = 22000, .container = 22000 },
                .{ .host = 22000, .container = 22000, .proto = .udp },
                .{ .host = 21027, .container = 21027, .proto = .udp },
            },
            .vols = &.{
                .{ .name = "config", .path = "/var/syncthing/config" },
                .{ .name = "sync", .path = "/var/syncthing/Sync", .param = true },
            },
        }},
    },
    .{
        .id = "gitea",
        .name = "Gitea",
        .category = .development,
        .blurb = "A light Git server with issues and pull requests, like a private GitHub.",
        .svcs = &.{.{
            .name = "app",
            .image = "gitea/gitea:latest",
            .ports = &.{
                .{ .host = 3002, .container = 3000, .web = true },
                .{ .host = 2222, .container = 22 },
            },
            .vols = &.{.{ .name = "data", .path = "/data" }},
        }},
    },
    .{
        .id = "mealie",
        .name = "Mealie",
        .category = .productivity,
        .blurb = "Recipe manager and meal planner for the whole household.",
        .notes = "First login: changeme@example.com with password MyPassword. Change it at once.",
        .svcs = &.{.{
            .name = "app",
            .image = "ghcr.io/mealie-recipes/mealie:latest",
            .ports = &.{.{ .host = 9925, .container = 9000, .web = true }},
            .env = &.{ tz, "ALLOW_SIGNUP=false" },
            .vols = &.{.{ .name = "data", .path = "/app/data" }},
        }},
    },
    .{
        .id = "actualbudget",
        .name = "Actual Budget",
        .category = .productivity,
        .blurb = "Private budgeting that works offline and syncs across devices.",
        .svcs = &.{.{
            .name = "app",
            .image = "actualbudget/actual-server:latest",
            .ports = &.{.{ .host = 5006, .container = 5006, .web = true }},
            .vols = &.{.{ .name = "data", .path = "/data" }},
        }},
    },
    .{
        .id = "stirlingpdf",
        .name = "Stirling PDF",
        .category = .productivity,
        .blurb = "Merge, split, convert and edit PDFs without uploading them anywhere.",
        .svcs = &.{.{
            .name = "app",
            .image = "stirlingtools/stirling-pdf:latest",
            .ports = &.{.{ .host = 8087, .container = 8080, .web = true }},
            .vols = &.{.{ .name = "configs", .path = "/configs" }},
        }},
    },
    .{
        .id = "freshrss",
        .name = "FreshRSS",
        .category = .productivity,
        .blurb = "Follow news sites and blogs in one self-hosted feed reader.",
        .svcs = &.{.{
            .name = "app",
            .image = "freshrss/freshrss:latest",
            .ports = &.{.{ .host = 8088, .container = 80, .web = true }},
            .env = &.{ tz, "CRON_MIN=1,31" },
            .vols = &.{
                .{ .name = "data", .path = "/var/www/FreshRSS/data" },
                .{ .name = "extensions", .path = "/var/www/FreshRSS/extensions" },
            },
        }},
    },
    .{
        .id = "memos",
        .name = "Memos",
        .category = .productivity,
        .blurb = "Quick private notes and a timeline of your thoughts.",
        .svcs = &.{.{
            .name = "app",
            .image = "neosmemo/memos:stable",
            .ports = &.{.{ .host = 5230, .container = 5230, .web = true }},
            .vols = &.{.{ .name = "data", .path = "/var/opt/memos" }},
        }},
    },
    .{
        .id = "ollama",
        .name = "Ollama",
        .category = .ai,
        .blurb = "Run open language models on your own hardware.",
        .notes = "Runs on the CPU. Models are large; each can take several GB. Pull one with: docker exec -it nodos-ollama-app ollama pull llama3.2",
        .svcs = &.{.{
            .name = "app",
            .image = "ollama/ollama:latest",
            .ports = &.{.{ .host = 11434, .container = 11434, .web = true }},
            .vols = &.{.{ .name = "models", .path = "/root/.ollama" }},
        }},
    },
    .{
        .id = "openwebui",
        .name = "Open WebUI",
        .category = .ai,
        .blurb = "A chat interface for your local language models.",
        .notes = "Talks to Ollama on this server (port 11434). Install Ollama first.",
        .svcs = &.{.{
            .name = "app",
            .image = "ghcr.io/open-webui/open-webui:main",
            .ports = &.{.{ .host = 8089, .container = 8080, .web = true }},
            .env = &.{"OLLAMA_BASE_URL=http://host.docker.internal:11434"},
            .extra_hosts = &.{"host.docker.internal:host-gateway"},
            .vols = &.{.{ .name = "data", .path = "/app/backend/data" }},
        }},
    },
};

pub fn find(id: []const u8) ?*const App {
    for (&catalog) |*a| if (std.mem.eql(u8, a.id, id)) return a;
    return null;
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c))) return false;
    return true;
}

const blocked_roots = [_][]const u8{ "/etc", "/proc", "/sys", "/dev", "/boot", "/root", "/run", "/var/run", "/var/lib/docker", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/opt/nodos", "/var/lib/nodos" };

/// A folder the user may share with an app. Absolute, plain characters, no
/// parent segments, and nothing that holds the system itself.
pub fn validPath(path: []const u8) bool {
    if (path.len < 2 or path.len > 200 or path[0] != '/') return false;
    if (path[path.len - 1] == '/' and path.len > 1) return false;
    for (path) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or c == '-' or c == '.' or c == ' ';
        if (!ok) return false;
    }
    var segs = std.mem.splitScalar(u8, path[1..], '/');
    while (segs.next()) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, "..") or std.mem.eql(u8, s, ".")) return false;
    }
    for (blocked_roots) |root| {
        if (std.mem.eql(u8, path, root)) return false;
        if (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/') return false;
    }
    return true;
}

pub const Options = struct {
    /// Host port for the web interface. Null keeps the default.
    port: ?u16 = null,
    /// Values for the app's folder parameters, by key.
    paths: []const KeyValue = &.{},
    lan_only: bool = false,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };

pub const PlanError = error{ MissingPath, BadPath, BadPort, OutOfMemory };

pub const Planned = struct {
    svc: []const u8,
    name: []const u8,
    image: []const u8,
    pull_image: []const u8,
    pull_tag: []const u8,
    body: []const u8,
};

pub const Plan = struct {
    network: []const u8,
    host_net: bool,
    containers: []Planned,
    web_port: u16,
    secret: []const u8,
};

pub fn containerName(arena: Allocator, app_id: []const u8, svc: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "nodos-{s}-{s}", .{ app_id, svc });
}

fn splitImage(image: []const u8) struct { name: []const u8, tag: []const u8 } {
    const slash = std.mem.findScalarLast(u8, image, '/') orelse 0;
    if (std.mem.findScalarPos(u8, image, slash, ':')) |c| return .{ .name = image[0..c], .tag = image[c + 1 ..] };
    return .{ .name = image, .tag = "latest" };
}

fn pathFor(opts: Options, key: []const u8) ?[]const u8 {
    for (opts.paths) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.value;
    return null;
}

fn expand(arena: Allocator, app: *const App, template: []const u8, secret: []const u8, secret2: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.findScalarPos(u8, template, i, '}')) |end| {
                const key = template[i + 1 .. end];
                if (std.mem.eql(u8, key, "secret")) {
                    try out.appendSlice(arena, secret);
                } else if (std.mem.eql(u8, key, "secret2")) {
                    try out.appendSlice(arena, secret2);
                } else if (std.mem.startsWith(u8, key, "name:")) {
                    try out.appendSlice(arena, try containerName(arena, app.id, key["name:".len..]));
                } else {
                    try out.appendSlice(arena, template[i .. end + 1]);
                }
                i = end + 1;
                continue;
            }
        }
        try out.append(arena, template[i]);
        i += 1;
    }
    return out.items;
}

fn hex(io: Io, arena: Allocator) Allocator.Error![]u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    return std.fmt.allocPrint(arena, "{x}", .{raw});
}

pub fn plan(arena: Allocator, io: Io, app: *const App, opts: Options) PlanError!Plan {
    var web_port: u16 = 0;
    for (app.svcs) |s| for (s.ports) |p| if (p.web) {
        web_port = opts.port orelse p.host;
    };
    if (opts.port) |p| if (p < 1024 and p != 81) return error.BadPort;
    if (web_port == 0 and !app.host_net) return error.BadPort;

    for (app.params) |p| {
        const v = pathFor(opts, p.key) orelse "";
        if (v.len == 0) {
            if (p.required) return error.MissingPath;
            continue;
        }
        if (!validPath(v)) return error.BadPath;
    }

    const secret = try hex(io, arena);
    const secret2 = try hex(io, arena);
    const network = try std.fmt.allocPrint(arena, "nodos-{s}", .{app.id});
    const bind_ip: []const u8 = if (opts.lan_only) "127.0.0.1" else "";

    var list: std.ArrayList(Planned) = .empty;
    for (app.svcs) |svc| {
        var aw: Io.Writer.Allocating = .init(arena);
        var j: std.json.Stringify = .{ .writer = &aw.writer };
        const name = try containerName(arena, app.id, svc.name);

        j.beginObject() catch return error.OutOfMemory;
        j.objectField("Image") catch return error.OutOfMemory;
        j.write(svc.image) catch return error.OutOfMemory;

        j.objectField("Env") catch return error.OutOfMemory;
        j.beginArray() catch return error.OutOfMemory;
        for (svc.env) |e| j.write(try expand(arena, app, e, secret, secret2)) catch return error.OutOfMemory;
        j.endArray() catch return error.OutOfMemory;

        if (svc.cmd.len > 0) {
            j.objectField("Cmd") catch return error.OutOfMemory;
            j.write(svc.cmd) catch return error.OutOfMemory;
        }

        j.objectField("Labels") catch return error.OutOfMemory;
        j.beginObject() catch return error.OutOfMemory;
        j.objectField("nodos.app") catch return error.OutOfMemory;
        j.write(app.id) catch return error.OutOfMemory;
        j.objectField("nodos.svc") catch return error.OutOfMemory;
        j.write(svc.name) catch return error.OutOfMemory;
        j.endObject() catch return error.OutOfMemory;

        if (!app.host_net and svc.ports.len > 0) {
            j.objectField("ExposedPorts") catch return error.OutOfMemory;
            j.beginObject() catch return error.OutOfMemory;
            for (svc.ports) |p| {
                const key = try std.fmt.allocPrint(arena, "{d}/{s}", .{ p.container, @tagName(p.proto) });
                j.objectField(key) catch return error.OutOfMemory;
                j.beginObject() catch return error.OutOfMemory;
                j.endObject() catch return error.OutOfMemory;
            }
            j.endObject() catch return error.OutOfMemory;
        }

        j.objectField("HostConfig") catch return error.OutOfMemory;
        j.beginObject() catch return error.OutOfMemory;

        if (!app.host_net and svc.ports.len > 0) {
            j.objectField("PortBindings") catch return error.OutOfMemory;
            j.beginObject() catch return error.OutOfMemory;
            for (svc.ports) |p| {
                const key = try std.fmt.allocPrint(arena, "{d}/{s}", .{ p.container, @tagName(p.proto) });
                const host_port = if (p.web) web_port else p.host;
                j.objectField(key) catch return error.OutOfMemory;
                j.beginArray() catch return error.OutOfMemory;
                j.beginObject() catch return error.OutOfMemory;
                j.objectField("HostIp") catch return error.OutOfMemory;
                j.write(bind_ip) catch return error.OutOfMemory;
                j.objectField("HostPort") catch return error.OutOfMemory;
                j.write(try std.fmt.allocPrint(arena, "{d}", .{host_port})) catch return error.OutOfMemory;
                j.endObject() catch return error.OutOfMemory;
                j.endArray() catch return error.OutOfMemory;
            }
            j.endObject() catch return error.OutOfMemory;
        }

        j.objectField("Binds") catch return error.OutOfMemory;
        j.beginArray() catch return error.OutOfMemory;
        for (svc.vols) |v| {
            if (v.param) {
                const host = pathFor(opts, v.name) orelse "";
                if (host.len == 0) continue;
                const mode: []const u8 = if (v.ro) ":ro" else "";
                j.write(try std.fmt.allocPrint(arena, "{s}:{s}{s}", .{ host, v.path, mode })) catch return error.OutOfMemory;
            } else {
                j.write(try std.fmt.allocPrint(arena, "nodos-{s}-{s}:{s}", .{ app.id, v.name, v.path })) catch return error.OutOfMemory;
            }
        }
        j.endArray() catch return error.OutOfMemory;

        j.objectField("RestartPolicy") catch return error.OutOfMemory;
        j.beginObject() catch return error.OutOfMemory;
        j.objectField("Name") catch return error.OutOfMemory;
        j.write("unless-stopped") catch return error.OutOfMemory;
        j.endObject() catch return error.OutOfMemory;

        j.objectField("NetworkMode") catch return error.OutOfMemory;
        j.write(if (app.host_net) "host" else network) catch return error.OutOfMemory;

        if (svc.caps.len > 0) {
            j.objectField("CapAdd") catch return error.OutOfMemory;
            j.write(svc.caps) catch return error.OutOfMemory;
        }
        if (svc.extra_hosts.len > 0) {
            j.objectField("ExtraHosts") catch return error.OutOfMemory;
            j.write(svc.extra_hosts) catch return error.OutOfMemory;
        }
        j.endObject() catch return error.OutOfMemory;

        if (!app.host_net) {
            j.objectField("NetworkingConfig") catch return error.OutOfMemory;
            j.beginObject() catch return error.OutOfMemory;
            j.objectField("EndpointsConfig") catch return error.OutOfMemory;
            j.beginObject() catch return error.OutOfMemory;
            j.objectField(network) catch return error.OutOfMemory;
            j.beginObject() catch return error.OutOfMemory;
            j.objectField("Aliases") catch return error.OutOfMemory;
            j.beginArray() catch return error.OutOfMemory;
            j.write(svc.name) catch return error.OutOfMemory;
            j.endArray() catch return error.OutOfMemory;
            j.endObject() catch return error.OutOfMemory;
            j.endObject() catch return error.OutOfMemory;
            j.endObject() catch return error.OutOfMemory;
        }

        j.endObject() catch return error.OutOfMemory;

        const img = splitImage(svc.image);
        try list.append(arena, .{
            .svc = svc.name,
            .name = name,
            .image = svc.image,
            .pull_image = img.name,
            .pull_tag = img.tag,
            .body = aw.written(),
        });
    }

    return .{
        .network = network,
        .host_net = app.host_net,
        .containers = list.items,
        .web_port = web_port,
        .secret = if (app.secret_label.len > 0) secret else "",
    };
}

pub fn categoryLabel(c: Category) []const u8 {
    return switch (c) {
        .media => "Media",
        .files => "Files and sync",
        .network => "Network",
        .automation => "Smart home",
        .monitoring => "Monitoring",
        .productivity => "Everyday",
        .development => "Development",
        .ai => "AI",
    };
}

pub const InstalledState = struct { running: usize = 0, total: usize = 0 };

pub fn writeCatalog(w: *Io.Writer, states: []const InstalledState, docker: []const u8) Io.Writer.Error!void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("docker");
    try j.write(docker);
    try j.objectField("apps");
    try j.beginArray();
    for (&catalog, 0..) |a, i| {
        const st = if (i < states.len) states[i] else InstalledState{};
        try j.beginObject();
        try j.objectField("id");
        try j.write(a.id);
        try j.objectField("name");
        try j.write(a.name);
        try j.objectField("category");
        try j.write(categoryLabel(a.category));
        try j.objectField("blurb");
        try j.write(a.blurb);
        try j.objectField("notes");
        try j.write(a.notes);
        try j.objectField("containers");
        try j.write(a.svcs.len);
        try j.objectField("installed");
        try j.write(st.total > 0);
        try j.objectField("running");
        try j.write(st.running);
        var web: u16 = 0;
        for (a.svcs) |s| for (s.ports) |p| if (p.web) {
            web = p.host;
        };
        try j.objectField("port");
        try j.write(web);
        try j.objectField("web_path");
        try j.write(a.web_path);
        try j.objectField("params");
        try j.beginArray();
        for (a.params) |p| {
            try j.beginObject();
            try j.objectField("key");
            try j.write(p.key);
            try j.objectField("label");
            try j.write(p.label);
            try j.objectField("help");
            try j.write(p.help);
            try j.objectField("required");
            try j.write(p.required);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
}

test "every catalog entry is well formed" {
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(std.testing.allocator);
    for (&catalog) |a| {
        try std.testing.expect(validId(a.id));
        try std.testing.expect(!(try ids.getOrPut(std.testing.allocator, a.id)).found_existing);
        try std.testing.expect(a.name.len > 0 and a.blurb.len > 0 and a.svcs.len > 0);
        var web_ports: usize = 0;
        for (a.svcs) |s| {
            try std.testing.expect(s.image.len > 0 and std.mem.findScalar(u8, s.image, ' ') == null);
            for (s.ports) |p| {
                if (p.web) web_ports += 1;
                try std.testing.expect(p.host > 0 and p.container > 0);
            }
            for (s.vols) |v| {
                try std.testing.expect(v.path[0] == '/');
                if (v.param) {
                    var found = false;
                    for (a.params) |pr| if (std.mem.eql(u8, pr.key, v.name)) {
                        found = true;
                    };
                    try std.testing.expect(found);
                }
            }
        }
        try std.testing.expect(web_ports == 1);
        for (a.params) |pr| {
            var used = false;
            for (a.svcs) |s| for (s.vols) |v| if (v.param and std.mem.eql(u8, v.name, pr.key)) {
                used = true;
            };
            try std.testing.expect(used);
        }
    }
}

test "default host ports of apps that publish a web port do not collide" {
    var seen: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (&catalog) |a| {
        if (a.host_net) continue;
        for (a.svcs) |s| for (s.ports) |p| {
            if (!p.web) continue;
            const key: u32 = p.host;
            const gop = try seen.getOrPut(std.testing.allocator, key);
            try std.testing.expect(!gop.found_existing);
            gop.value_ptr.* = a.id;
        };
    }
}

test "folder validation" {
    try std.testing.expect(validPath("/srv/media"));
    try std.testing.expect(validPath("/mnt/disk 1/Movies"));
    try std.testing.expect(!validPath("media"));
    try std.testing.expect(!validPath("/"));
    try std.testing.expect(!validPath("/srv/../etc"));
    try std.testing.expect(!validPath("/srv/media/"));
    try std.testing.expect(!validPath("/srv/a:b"));
    try std.testing.expect(!validPath("/srv/a,b"));
    try std.testing.expect(!validPath("/srv//a"));
    try std.testing.expect(!validPath("/etc"));
    try std.testing.expect(!validPath("/etc/nodos"));
    try std.testing.expect(!validPath("/var/lib/docker/volumes"));
    try std.testing.expect(!validPath("/proc/1"));
    try std.testing.expect(!validPath("/srv/a\nb"));
    try std.testing.expect(validPath("/etcetera"));
}

fn parsed(arena: Allocator, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
}

test "plan: single container app" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try plan(a, std.testing.io, find("navidrome").?, .{ .paths = &.{.{ .key = "music", .value = "/srv/music" }}, .port = 4600 });
    try std.testing.expectEqual(@as(usize, 1), p.containers.len);
    try std.testing.expectEqualStrings("nodos-navidrome-app", p.containers[0].name);
    try std.testing.expectEqualStrings("deluan/navidrome", p.containers[0].pull_image);
    try std.testing.expectEqualStrings("latest", p.containers[0].pull_tag);
    try std.testing.expectEqual(@as(u16, 4600), p.web_port);
    const v = try parsed(a, p.containers[0].body);
    const host = v.object.get("HostConfig").?.object;
    try std.testing.expectEqualStrings("nodos-navidrome", host.get("NetworkMode").?.string);
    const binds = host.get("Binds").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), binds.len);
    try std.testing.expectEqualStrings("nodos-navidrome-data:/data", binds[0].string);
    try std.testing.expectEqualStrings("/srv/music:/music:ro", binds[1].string);
    const pb = host.get("PortBindings").?.object.get("4533/tcp").?.array.items[0].object;
    try std.testing.expectEqualStrings("4600", pb.get("HostPort").?.string);
    try std.testing.expectEqualStrings("", pb.get("HostIp").?.string);
    try std.testing.expectEqualStrings("navidrome", v.object.get("Labels").?.object.get("nodos.app").?.string);
}

test "plan: multi container app shares secrets and names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try plan(a, std.testing.io, find("immich").?, .{ .lan_only = true });
    try std.testing.expectEqual(@as(usize, 4), p.containers.len);
    const db = try parsed(a, p.containers[0].body);
    const srv = try parsed(a, p.containers[3].body);
    var db_pw: []const u8 = "";
    for (db.object.get("Env").?.array.items) |e| if (std.mem.startsWith(u8, e.string, "POSTGRES_PASSWORD=")) {
        db_pw = e.string["POSTGRES_PASSWORD=".len..];
    };
    try std.testing.expectEqual(@as(usize, 32), db_pw.len);
    var srv_pw: []const u8 = "";
    var db_host: []const u8 = "";
    for (srv.object.get("Env").?.array.items) |e| {
        if (std.mem.startsWith(u8, e.string, "DB_PASSWORD=")) srv_pw = e.string["DB_PASSWORD=".len..];
        if (std.mem.startsWith(u8, e.string, "DB_HOSTNAME=")) db_host = e.string["DB_HOSTNAME=".len..];
    }
    try std.testing.expectEqualStrings(db_pw, srv_pw);
    try std.testing.expectEqualStrings("nodos-immich-db", db_host);
    const pb = srv.object.get("HostConfig").?.object.get("PortBindings").?.object.get("2283/tcp").?.array.items[0].object;
    try std.testing.expectEqualStrings("127.0.0.1", pb.get("HostIp").?.string);
    const alias = srv.object.get("NetworkingConfig").?.object.get("EndpointsConfig").?.object.get("nodos-immich").?.object.get("Aliases").?.array.items[0].string;
    try std.testing.expectEqualStrings("server", alias);
}

test "plan: host network apps publish nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try plan(a, std.testing.io, find("homeassistant").?, .{});
    try std.testing.expect(p.host_net);
    const v = try parsed(a, p.containers[0].body);
    try std.testing.expectEqualStrings("host", v.object.get("HostConfig").?.object.get("NetworkMode").?.string);
    try std.testing.expect(v.object.get("HostConfig").?.object.get("PortBindings") == null);
    try std.testing.expect(v.object.get("NetworkingConfig") == null);
}

test "plan: bad input is refused before anything is built" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jf = find("jellyfin").?;
    try std.testing.expectError(error.MissingPath, plan(a, std.testing.io, jf, .{}));
    try std.testing.expectError(error.BadPath, plan(a, std.testing.io, jf, .{ .paths = &.{.{ .key = "media", .value = "/srv/../etc" }} }));
    try std.testing.expectError(error.BadPath, plan(a, std.testing.io, jf, .{ .paths = &.{.{ .key = "media", .value = "/srv/x:/etc:rw" }} }));
    try std.testing.expectError(error.BadPort, plan(a, std.testing.io, jf, .{ .port = 22, .paths = &.{.{ .key = "media", .value = "/srv/x" }} }));
    _ = try plan(a, std.testing.io, jf, .{ .paths = &.{.{ .key = "media", .value = "/srv/x" }} });
}

test "optional folders are skipped when empty" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try plan(a, std.testing.io, find("paperless").?, .{});
    const web = try parsed(a, p.containers[2].body);
    const binds = web.object.get("HostConfig").?.object.get("Binds").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), binds.len);
}

test "catalog json parses" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCatalog(&out.writer, &.{}, "ok");
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer v.deinit();
    try std.testing.expectEqual(catalog.len, v.value.object.get("apps").?.array.items.len);
}
