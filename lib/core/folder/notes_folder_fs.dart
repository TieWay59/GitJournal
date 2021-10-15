/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'dart:collection';

import 'package:dart_git/plumbing/git_hash.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:path/path.dart' as p;
import 'package:path/path.dart';
import 'package:synchronized/synchronized.dart';
import 'package:universal_io/io.dart' as io;

import 'package:gitjournal/core/note_storage.dart';
import 'package:gitjournal/core/views/inline_tags_view.dart';
import 'package:gitjournal/generated/locale_keys.g.dart';
import 'package:gitjournal/logger/logger.dart';
import '../file/file.dart';
import '../file/ignored_file.dart';
import '../note.dart';
import 'notes_folder.dart';
import 'notes_folder_notifier.dart';

class NotesFolderFS with NotesFolderNotifier implements NotesFolder {
  final NotesFolderFS? _parent;
  String _folderPath;
  final _lock = Lock();

  var _files = <File>[];
  var _folders = <NotesFolderFS>[];
  var _entityMap = <String, dynamic>{};

  final NotesFolderConfig _config;

  NotesFolderFS(this._parent, this._folderPath, this._config);

  @override
  void dispose() {
    for (var f in _folders) {
      f.removeListener(_entityChanged);
    }

    super.dispose();
  }

  @override
  NotesFolder? get parent => _parent;

  NotesFolderFS? get parentFS => _parent;

  void _entityChanged() {
    notifyListeners();
  }

  void noteModified(Note note) {
    if (_entityMap.containsKey(note.filePath)) {
      notifyNoteModified(-1, note);
    }
  }

  void _noteRenamed(Note note, String oldPath) {
    _lock.synchronized(() {
      assert(_entityMap.containsKey(oldPath));
      _entityMap.remove(oldPath);
      _entityMap[note.filePath] = note;

      notifyNoteRenamed(-1, note, oldPath);
    });
  }

  void _subFolderRenamed(NotesFolderFS folder, String oldPath) {
    _lock.synchronized(() {
      assert(_entityMap.containsKey(oldPath));
      _entityMap.remove(oldPath);
      _entityMap[folder.folderPath] = folder;
    });
  }

  void reset(String folderPath) {
    _folderPath = folderPath;

    var filesCopy = List<File>.from(_files);
    filesCopy.forEach(_removeFile);

    var foldersCopy = List<NotesFolderFS>.from(_folders);
    foldersCopy.forEach(removeFolder);

    assert(_files.isEmpty);
    assert(_folders.isEmpty);

    notifyListeners();
  }

  String get folderPath => _folderPath;

  @override
  bool get isEmpty {
    return !hasNotes && _folders.isEmpty;
  }

  @override
  String get name => basename(folderPath);

  bool get hasSubFolders {
    return _folders.isNotEmpty;
  }

  @override
  bool get hasNotes {
    return _files.indexWhere((n) => n is Note) != -1;
  }

  bool get hasNotesRecursive {
    if (hasNotes) {
      return true;
    }

    for (var folder in _folders) {
      if (folder.hasNotesRecursive) {
        return true;
      }
    }
    return false;
  }

  int get numberOfNotes {
    return notes.length;
  }

  @override
  List<Note> get notes {
    return _files.whereType<Note>().toList();
  }

  @override
  List<NotesFolder> get subFolders => subFoldersFS;

  List<IgnoredFile> get ignoredFiles =>
      _files.whereType<IgnoredFile>().toList();

  List<NotesFolderFS> get subFoldersFS {
    // FIXME: This is really not ideal
    _folders.sort((NotesFolderFS a, NotesFolderFS b) =>
        a.folderPath.compareTo(b.folderPath));
    return _folders;
  }

  // FIXME: This asynchronously loads everything. Maybe it should just list them, and the individual _entities
  //        should be loaded as required?
  Future<void> loadRecursively() async {
    const maxParallel = 10;
    var futures = <Future>[];

    await load();

    var storage = NoteStorage();
    for (var file in _files) {
      if (file is! Note) {
        continue;
      }
      var note = file;

      // FIXME: Collected all the Errors, and report them back, along with "WHY", and the contents of the Note
      //        Each of these needs to be reported to sentry, as Note loading should never fail
      var f = storage.load(note);
      futures.add(f);

      if (futures.length >= maxParallel) {
        await Future.wait(futures);
        futures = <Future>[];
      }
    }

    await Future.wait(futures);
    futures = <Future>[];

    // Remove notes which have errors
    await _lock.synchronized(() {
      _files = _files.map((f) {
        if (f is! Note) {
          return f;
        }

        var note = f;
        if (note.loadState != NoteLoadState.Error) {
          return note;
        }

        notifyNoteRemoved(-1, note);

        return IgnoredFile(
          oid: note.oid,
          filePath: note.filePath,
          created: note.created,
          modified: note.modified,
          fileLastModified: note.fileLastModified,
          reason: IgnoreReason.Custom,
        );
      }).toList();
    });

    for (var folder in _folders) {
      var f = folder.loadRecursively();
      futures.add(f);
    }

    await Future.wait(futures);
  }

  Future<void> load() => _lock.synchronized(_load);

  Future<void> _load() async {
    var ignoreFilePath = p.join(folderPath, ".gjignore");
    if (io.File(ignoreFilePath).existsSync()) {
      Log.i("Ignoring $folderPath as it has .gjignore");
      return;
    }

    var newEntityMap = <String, dynamic>{};
    var newFiles = <File>[];
    var newFolders = <NotesFolderFS>[];

    final dir = io.Directory(folderPath);
    var lister = dir.list(recursive: false, followLinks: false);
    await for (var fsEntity in lister) {
      if (fsEntity is io.Link) {
        continue;
      }

      if (fsEntity is io.Directory) {
        var subFolder = NotesFolderFS(this, fsEntity.path, _config);
        if (subFolder.name.startsWith('.')) {
          // Log.v("Ignoring Folder", props: {
          //   "path": fsEntity.path,
          //   "reason": "Hidden folder",
          // });
          continue;
        }
        // Log.v("Found Folder", props: {"path": fsEntity.path});

        newFolders.add(subFolder);
        newEntityMap[fsEntity.path] = subFolder;
        continue;
      }

      var stat = fsEntity.statSync();
      var filePath = fsEntity.path;

      var fileName = p.basename(filePath);
      if (fileName.startsWith('.')) {
        var ignoredFile = IgnoredFile(
          filePath: filePath,
          oid: GitHash.zero(),
          created: null,
          modified: null,
          fileLastModified: stat.modified,
          reason: IgnoreReason.HiddenFile,
        );

        newFiles.add(ignoredFile);
        newEntityMap[filePath] = ignoredFile;
        continue;
      }
      if (!NoteFileFormatInfo.isAllowedFileName(filePath)) {
        var ignoredFile = IgnoredFile(
          filePath: filePath,
          oid: GitHash.zero(),
          created: null,
          modified: null,
          fileLastModified: stat.modified,
          reason: IgnoreReason.InvalidExtension,
        );

        newFiles.add(ignoredFile);
        newEntityMap[filePath] = ignoredFile;
        continue;
      }

      // Log.v("Found file", props: {"path": filePath});
      var note = Note(this, filePath, stat.modified);

      newFiles.add(note);
      newEntityMap[filePath] = note;
    }

    var originalPathsList = _entityMap.keys.toSet();
    var newPathsList = newEntityMap.keys.toSet();

    var origEntityMap = _entityMap;
    _entityMap = newEntityMap;
    _files = newFiles;
    _folders = newFolders;

    var pathsRemoved = originalPathsList.difference(newPathsList);
    for (var path in pathsRemoved) {
      var e = origEntityMap[path];
      assert(e is NotesFolder || e is File);

      if (e is File) {
        if (e is Note) {
          notifyNoteRemoved(-1, e);
        }
      } else {
        _removeFolderListeners(e);
        notifyFolderRemoved(-1, e);
      }
    }

    var pathsAdded = newPathsList.difference(originalPathsList);
    for (var path in pathsAdded) {
      var e = _entityMap[path];
      assert(e is NotesFolder || e is File);

      if (e is File) {
        if (e is Note) {
          notifyNoteAdded(-1, e);
        }
      } else {
        _addFolderListeners(e);
        notifyFolderAdded(-1, e);
      }
    }
  }

  void add(Note note) {
    assert(note.parent == this);

    _files.add(note);
    _entityMap[note.filePath] = note;

    notifyNoteAdded(-1, note);
  }

  void remove(Note note) {
    assert(note.parent == this);
    _removeFile(note);
  }

  void _removeFile(File f) {
    assert(_files.indexWhere((n) => n.filePath == f.filePath) != -1);
    assert(_entityMap.containsKey(f.filePath));

    var index = _files.indexWhere((n) => n.filePath == f.filePath);
    _files.removeAt(index);

    if (f is Note) {
      notifyNoteRemoved(index, f);
    }
  }

  void create() {
    // Git doesn't track Directories, only files, so we create an empty .gitignore file
    // in the directory instead.
    var gitIgnoreFilePath = p.join(folderPath, ".gitignore");
    var file = io.File(gitIgnoreFilePath);
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    notifyListeners();
  }

  void addFolder(NotesFolderFS folder) {
    assert(folder.parent == this);
    _addFolderListeners(folder);

    _folders.add(folder);
    _entityMap[folder.folderPath] = folder;

    notifyFolderAdded(_folders.length - 1, folder);
  }

  void removeFolder(NotesFolderFS folder) {
    var filesCopy = List<File>.from(folder._files);
    filesCopy.forEach(folder._removeFile);

    var foldersCopy = List<NotesFolderFS>.from(folder._folders);
    foldersCopy.forEach(folder.removeFolder);

    _removeFolderListeners(folder);

    assert(_folders.indexWhere((f) => f.folderPath == folder.folderPath) != -1);
    assert(_entityMap.containsKey(folder.folderPath));

    var index = _folders.indexWhere((f) => f.folderPath == folder.folderPath);
    assert(index != -1);
    _folders.removeAt(index);
    _entityMap.remove(folder.folderPath);

    notifyFolderRemoved(index, folder);
  }

  void rename(String newName) {
    var oldPath = _folderPath;
    var dir = io.Directory(_folderPath);
    _folderPath = p.join(dirname(_folderPath), newName);
    dir.renameSync(_folderPath);

    notifyThisFolderRenamed(this, oldPath);
  }

  void _addFolderListeners(NotesFolderFS folder) {
    folder.addListener(_entityChanged);
    folder.addThisFolderRenamedListener(_subFolderRenamed);
  }

  void _removeFolderListeners(NotesFolderFS folder) {
    folder.removeListener(_entityChanged);
    folder.removeThisFolderRenamedListener(_subFolderRenamed);
  }

  @override
  String pathSpec() {
    if (parent == null) {
      return "";
    }
    return p.join(parent!.pathSpec(), name);
  }

  @override
  String get publicName {
    var spec = pathSpec();
    if (spec.isEmpty) {
      return tr(LocaleKeys.rootFolder);
    }
    return spec;
  }

  Iterable<Note> getAllNotes() sync* {
    for (var f in _files) {
      if (f is Note) {
        yield f;
      }
    }

    for (var folder in _folders) {
      var notes = folder.getAllNotes();
      for (var note in notes) {
        yield note;
      }
    }
  }

  @override
  NotesFolder get fsFolder {
    return this;
  }

  NotesFolderFS? getFolderWithSpec(String spec) {
    if (pathSpec() == spec) {
      return this;
    }
    for (var f in _folders) {
      var res = f.getFolderWithSpec(spec);
      if (res != null) {
        return res;
      }
    }

    return null;
  }

  NotesFolderFS get rootFolder {
    var folder = this;
    while (folder.parent != null) {
      folder = folder.parent as NotesFolderFS;
    }
    return folder;
  }

  Note? getNoteWithSpec(String spec) {
    // FIXME: Once each note is stored with the spec as the path, this becomes
    //        so much easier!
    var parts = spec.split(p.separator);
    var folder = this;
    while (parts.length != 1) {
      var folderName = parts[0];

      bool foundFolder = false;
      for (var f in _folders) {
        if (f.name == folderName) {
          folder = f;
          foundFolder = true;
          break;
        }
      }

      if (!foundFolder) {
        return null;
      }
      parts.removeAt(0);
    }

    var fileName = parts[0];
    for (var note in folder.notes) {
      if (note.fileName == fileName) {
        return note;
      }
    }

    return null;
  }

  @override
  NotesFolderConfig get config => _config;

  Future<SplayTreeSet<String>> getNoteTagsRecursively(
    InlineTagsView inlineTagsView,
  ) async {
    return _fetchTags(this, inlineTagsView, SplayTreeSet<String>());
  }

  Future<List<Note>> matchNotes(NoteMatcherAsync pred) async {
    var matchedNotes = <Note>[];
    await _matchNotes(matchedNotes, pred);
    return matchedNotes;
  }

  Future<List<Note>> _matchNotes(
    List<Note> matchedNotes,
    NoteMatcherAsync pred,
  ) async {
    for (var file in _files) {
      if (file is! Note) {
        continue;
      }
      var note = file;
      var matches = await pred(note);
      if (matches) {
        matchedNotes.add(note);
      }
    }

    for (var folder in _folders) {
      await folder._matchNotes(matchedNotes, pred);
    }
    return matchedNotes;
  }

  ///
  /// Do not let the user rename it to a different file-type.
  ///
  void renameNote(Note note, String newName) {
    switch (note.fileFormat) {
      case NoteFileFormat.OrgMode:
        if (!newName.toLowerCase().endsWith('.org')) {
          newName += '.org';
        }
        break;

      case NoteFileFormat.Txt:
        if (!newName.toLowerCase().endsWith('.txt')) {
          newName += '.txt';
        }
        break;

      case NoteFileFormat.Markdown:
      default:
        if (!newName.toLowerCase().endsWith('.md')) {
          newName += '.md';
        }
        break;
    }

    var oldFilePath = note.filePath;
    var parentDirName = p.dirname(oldFilePath);
    var newFilePath = p.join(parentDirName, newName);

    // The file will not exist for new notes
    var file = io.File(oldFilePath);
    if (file.existsSync()) {
      file.renameSync(newFilePath);
    }
    note.apply(filePath: newFilePath);

    _noteRenamed(note, oldFilePath);
  }

  static bool moveNote(Note note, NotesFolderFS destFolder) {
    var destPath = p.join(destFolder.folderPath, note.fileName);
    if (io.File(destPath).existsSync()) {
      return false;
    }

    io.File(note.filePath).renameSync(destPath);

    note.parent.remove(note);
    note.parent = destFolder;
    note.parent.add(note);

    return true;
  }
}

typedef NoteMatcherAsync = Future<bool> Function(Note n);

Future<SplayTreeSet<String>> _fetchTags(
  NotesFolder folder,
  InlineTagsView inlineTagsView,
  SplayTreeSet<String> tags,
) async {
  for (var note in folder.notes) {
    tags.addAll(note.tags);
    tags.addAll(await inlineTagsView.fetch(note));
  }

  for (var folder in folder.subFolders) {
    tags = await _fetchTags(folder, inlineTagsView, tags);
  }

  return tags;
}
