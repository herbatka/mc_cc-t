// Dumps every loaded recipe to the KubeJS log.
// Save as a server_scripts file (e.g. kubejs/server_scripts/dump_recipes.js)
// and it runs automatically on server (re)start / reload.
//
// r.json.toString() is required, not JSON.stringify(r.json) - r.json is a
// raw Java Gson JsonObject, and JSON.stringify() on a Java object reflects
// its class's method signatures instead of its actual contents. toString()
// on a Gson JsonObject correctly produces real JSON text.
ServerEvents.recipes(event => {
  let count = 0
  event.forEachRecipe({}, r => {
    count++
    try {
      console.log('RECIPEDUMP ' + r.id + ' ' + r.json.toString())
    } catch (e) {
      console.log('RECIPEDUMP ' + r.id + ' <no-json>')
    }
  })
  console.log('RECIPEDUMP_TOTAL ' + count)
})
