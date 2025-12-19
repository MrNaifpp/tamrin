//
//  ProfileView.swift
//  Sirr
//
//  Created by فارس أبومالح on 15/05/1447 AH.
//

import SwiftUI

struct ProfileView: View {
    var body: some View {
        DatePicker(selection: /*@START_MENU_TOKEN@*/.constant(Date())/*@END_MENU_TOKEN@*/, label: { /*@START_MENU_TOKEN@*/Text("Date")/*@END_MENU_TOKEN@*/ })
        List {
            Text("حسابي")
            Text("حسابي")
            Text("حسابي")
            Text("حسابي")
        }
    }
}

#Preview {
    ProfileView()
}
