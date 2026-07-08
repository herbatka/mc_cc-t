// Dumps the concrete item ids for EVERY item tag currently known to the
// game (vanilla + every mod), not just tags referenced by some recipe.
// Save as a server_scripts file (e.g. kubejs/server_scripts/dump_all_tags.js)
// and it runs automatically on server (re)start / reload.
//
// An earlier version of this dump only walked tags actually used as a
// recipe INGREDIENT reference - fine for resolving what a recipe needs,
// but it missed purely-classification tags nothing ever crafts with, like
// c:crops on a farming mod's produce. This dumps every tag the item
// registry itself knows about instead, so tag search in the Search tab
// (see README.md) actually covers things like that.
//
// NOTE: ServerEvents.tags fires multiple times during server startup/reload;
// early firings (before tags fully resolve) return empty/garbage results, and
// a later "Worker-ResourceReload" thread firing has the real resolved data.
// db/parse_tag_log.py handles this (keeps the LAST occurrence per tag) - it's
// expected and not a bug if you see a tag logged more than once.
ServerEvents.tags('item', event => {
  let count = 0
  try {
    let itemRegistry = event.server.registryAccess()
      .registryOrThrow(Packages.net.minecraft.core.registries.Registries.ITEM)
    let tagKeys = itemRegistry.getTagNames().toArray()

    for (let i = 0; i < tagKeys.length; i++) {
      let tagId = String(tagKeys[i].location())
      try {
        let ids = event.get(tagId).getObjectIds()
        // ids is a Java List, not a JS array - .map()/.forEach() don't work
        // on it the way they would on a real array, so build one by hand.
        let arr = []
        for (let j = 0; j < ids.size(); j++) {
          arr.push(String(ids.get(j)))
        }
        console.log('TAGDUMP ' + tagId + ' ' + JSON.stringify(arr))
        count++
      } catch (e) {
        console.log('TAGDUMP ' + tagId + ' <error: ' + e + '>')
      }
    }
  } catch (e) {
    // If the registry-enumeration part itself fails (wrong method/class
    // name for this KubeJS/Minecraft version), this is what to send back -
    // it means the tag LIST couldn't be built at all, not a per-tag issue.
    console.log('ENUMERATE_TAGS_ERROR ' + e)
  }
  console.log('TAGDUMP_TOTAL ' + count)
})
