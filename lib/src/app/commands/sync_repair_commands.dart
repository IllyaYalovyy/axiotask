part of '../commands.dart';

/// Which side of a conflicted pair the user is keeping (#296).
enum ConflictChoice {
  /// The local edit that lost the `412` — the copy's content becomes the
  /// canonical row's, and the copy goes.
  keepMine,

  /// Google's content — the canonical row is already it, so only the copy goes.
  keepTheirs,

  /// Both rows, as two ordinary tasks. Nothing is deleted and no content
  /// changes; only the "(conflicted copy)" MARKER is dropped, because the
  /// marker is the app's word, not the user's, and while it is there the pair
  /// keeps presenting itself as a decision the user has already made.
  keepBoth,
}

/// The undo handle for [Commands.resolveConflict]: both rows exactly as they
/// were, plus the delete that has to be reversed when one of them was taken
/// away. Held in memory by the undo toast, like [DeleteToken].
class ConflictToken {
  const ConflictToken({
    required this.originalBefore,
    required this.copyBefore,
    this.deleted,
  });

  /// The canonical row before the resolution.
  final StoredTask originalBefore;

  /// The conflicted copy before the resolution.
  final StoredTask copyBefore;

  /// The copy's delete, when the choice removed it — reversed through
  /// [Commands.undoDelete]'s own path so a tombstone that already pushed is
  /// rebuilt rather than resurrected as a duplicate.
  final DeleteToken? deleted;
}

/// The undo handle for [Commands.discardLocalChange]: the row exactly as it was
/// before the local change was thrown away.
class DiscardToken {
  const DiscardToken({required this.rowBefore, this.deleted});

  /// The dirty row as it stood, with the change the user discarded.
  final StoredTask rowBefore;

  /// The delete, when the discarded change WAS the row (an unpushed create).
  final DeleteToken? deleted;
}

/// The repairs the "Needs attention" view performs (#296) — the commands that
/// resolve what the SYNC layer left behind, as opposed to what the user is
/// editing.
///
/// It borrows the lifecycle unit for its deletes: taking a row away has one
/// correct spelling (tombstone what Google may hold, hard-delete what it cannot,
/// capture the subtree for undo) and a second copy of that rule here would be
/// the kind of drift #271 split these units to prevent.
class SyncRepairCommands extends CommandUnit {
  SyncRepairCommands(super.store, super.newId, this._lifecycle);

  final TaskLifecycleCommands _lifecycle;

  /// Throw away a row's unpushed local change and adopt what the server holds —
  /// the "Discard local change" the view offers on a quarantined row.
  ///
  /// The row's BASE snapshot (#124) is the content as of its last agreement
  /// with Google, so restoring it and marking the row clean IS adopting the
  /// server's copy: nothing is pushed, and the next pull confirms it.
  ///
  /// A row with no base has never agreed with the server on anything — it is an
  /// unpushed create the server refused. There is no copy to adopt, so the
  /// change and the row are the same thing and the row goes (through the
  /// lifecycle delete, which tombstones it if the insert may have landed after
  /// all).
  Future<DiscardToken> discardLocalChange(String id) async {
    final row = await _findTask(id);
    final base = await _store.baseSnapshot(id);
    if (base == null) {
      return DiscardToken(
        rowBefore: row,
        deleted: await _lifecycle.deleteTask(id),
      );
    }
    await _store.upsertTask(
      StoredTask(
        task: row.task.copyWith(
          title: base.title,
          notes: base.notes,
          due: base.due,
          status: base.status,
          // A base that is not completed cannot carry a completion stamp; one
          // that is takes the row's own (the stamp is Google's, and the row
          // still holds the last one it agreed on).
          completed: base.status == TaskStatus.completed
              ? row.task.completed
              : null,
        ),
        listId: row.listId,
        syncState: SyncState.clean,
        localUpdated: row.localUpdated,
        remoteId: row.remoteId,
      ),
    );
    return DiscardToken(rowBefore: row);
  }

  /// Put a discarded local change back, exactly as it was.
  Future<void> undoDiscardLocalChange(DiscardToken token) async {
    final deleted = token.deleted;
    if (deleted != null) {
      await _lifecycle.undoDelete(deleted);
      return;
    }
    await _store.upsertTask(token.rowBefore);
  }

  /// Resolve a conflicted pair — see [ConflictChoice].
  ///
  /// The whole resolution is ONE transaction: "Keep mine" writes the canonical
  /// row AND removes the copy, and a half-applied version of that is either two
  /// rows with the same content or none at all.
  Future<ConflictToken> resolveConflict({
    required String originalId,
    required String copyId,
    required ConflictChoice choice,
  }) async {
    final original = await _findTask(originalId);
    final copy = await _findTask(copyId);
    final now = nowUtcString();

    return _store.transaction(() async {
      switch (choice) {
        case ConflictChoice.keepMine:
          await _store.upsertTask(
            _markDirty(
              original,
              original.task.copyWith(
                title: strippedCopyTitle(copy.task.title),
                notes: copy.task.notes,
                due: copy.task.due,
                status: copy.task.status,
                completed: copy.task.completed,
              ),
              now,
            ),
          );
          return ConflictToken(
            originalBefore: original,
            copyBefore: copy,
            deleted: await _lifecycle.deleteTask(copyId),
          );
        case ConflictChoice.keepTheirs:
          return ConflictToken(
            originalBefore: original,
            copyBefore: copy,
            deleted: await _lifecycle.deleteTask(copyId),
          );
        case ConflictChoice.keepBoth:
          await _store.upsertTask(
            _markDirty(
              copy,
              copy.task.copyWith(title: strippedCopyTitle(copy.task.title)),
              now,
            ),
          );
          return ConflictToken(originalBefore: original, copyBefore: copy);
      }
    });
  }

  /// Put both rows of a resolved conflict back exactly as they were.
  Future<void> undoResolveConflict(ConflictToken token) async {
    await _store.transaction(() async {
      await _store.upsertTask(token.originalBefore);
      final deleted = token.deleted;
      if (deleted != null) {
        await _lifecycle.undoDelete(deleted);
      } else {
        await _store.upsertTask(token.copyBefore);
      }
    });
  }
}
